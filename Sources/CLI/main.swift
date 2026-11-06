import Foundation
import Darwin

// lantern — control the Lantern plan viewer.

let usage = """
lantern — live plan viewer for your terminal workflow

  lantern <file.md|dir>...          open plans (same as `lantern open`)
  lantern open <file|dir>... [--window|--pane] [--width N] [--side left|right] [--lite|--full] [--focus] [--split]
  lantern close [file]              close one plan, or the whole pane when no file is given
  lantern switch <file|index|name>  show another open plan
  lantern width <percent>           set pane width (saved)
  lantern list                      list open plans
  lantern snapshot <out.png>        save a PNG of the viewer
  lantern mcp                       run as an MCP server over stdio (lets Claude control the viewer)
"""

var softErrors = false   // MCP mode: report failures to the client instead of exiting
struct SoftError: Error { let msg: String }
func die(_ m: String, _ code: Int32 = 1) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(code) }

// MARK: socket client
func connectSock() -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
    let path = LPaths.socket
    guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { die("socket path too long: \(path)") }
    withUnsafeMutablePointer(to: &addr.sun_path) { p in
        p.withMemoryRebound(to: CChar.self, capacity: 104) { _ = strlcpy($0, path, 104) }
    }
    let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    if r != 0 { close(fd); return nil }
    return fd
}
func launchApp() {
    let env = ProcessInfo.processInfo.environment
    var candidates = [env["LANTERN_APP"], "/Applications/Lantern.app", NSHomeDirectory() + "/Applications/Lantern.app"].compactMap { $0 }
    candidates = candidates.filter { FileManager.default.fileExists(atPath: $0) }
    guard let app = candidates.first else { if softErrors { return }; die("Lantern.app not found (run scripts/install.sh, or set LANTERN_APP)") }
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    var args = ["-g"]   // -g: don't steal focus from the terminal
    for k in ["LANTERN_HOME", "LANTERN_TEST"] { if let v = env[k] { args += ["--env", "\(k)=\(v)"] } }
    p.arguments = args + [app]
    try? p.run(); p.waitUntilExit()
}
func request(_ obj: [String: Any], launch: Bool = true, timeout: Double = 15) -> [String: Any] {
    if softErrors {
        var fd = connectSock()
        if fd == nil && launch {
            launchApp()
            for _ in 0..<100 { usleep(100_000); fd = connectSock(); if fd != nil { break } }
        }
        if let f = fd { close(f) } else { return ["error": "Lantern is not running and could not be launched (is Lantern.app installed? run scripts/install.sh)"] }
    }
    var fd = connectSock()
    if fd == nil && launch {
        launchApp()
        for _ in 0..<100 { usleep(100_000); fd = connectSock(); if fd != nil { break } }
    }
    guard let s = fd else { die("Lantern is not running") }
    var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var line = (try! JSONSerialization.data(withJSONObject: obj))
    line.append(10)
    _ = line.withUnsafeBytes { write(s, $0.baseAddress, line.count) }
    var buf = Data(); var chunk = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(s, &chunk, chunk.count)
        if n <= 0 { break }
        buf.append(chunk, count: n)
        if buf.last == 10 { break }
    }
    close(s)
    return ((try? JSONSerialization.jsonObject(with: buf)) as? [String: Any]) ?? [:]
}

// MARK: helpers
func planStatus(_ file: String) -> (PlanState, String, String) {
    let path = Store.resolve(file)
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { die("cannot read \(path)") }
    let st = Store.load(path)
    return (st, Store.effectiveStatus(st, content: content), path)
}
func exitCode(_ s: String) -> Int32 { s == "approved" ? 0 : s == "changes" ? 2 : 4 }

func ghosttySplit() {
    let script = """
    tell application "Ghostty"
      set t to focused terminal of selected tab of front window
      split t direction right
    end tell
    """
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript"); p.arguments = ["-e", script]
    try? p.run(); p.waitUntilExit()
    usleep(400_000)
}

// MARK: MCP server (newline-delimited JSON-RPC 2.0 over stdio)
let mcpInstructions = """
Lantern is a lean markdown viewer that shows your plans live, next to the user's terminal. It is view-only: the user reads, you keep working.
- When you write or substantially update a plan/spec/design doc (a .md file), call lantern_open with its absolute path so the user can read it rendered. Opening a folder shows every .md in it as tabs.
- Edits you make to an open file appear live (changed blocks glow), so do NOT re-open after editing. Just keep writing the file.
- Use lantern_switch to bring a different open file to the front, lantern_close when the doc is no longer relevant, lantern_list to see what is open.
- mode "pane" (default) overlays the right 40% of the front Ghostty window; mode "window" opens a normal resizable window. Use lantern_layout to change the pane width (10-90 percent) or side (left/right) if the user asks for more/less room.
- lantern_screenshot saves a PNG of the viewer if you need to check how something rendered.
- Do not steal focus: leave focus false unless the user asks to jump to the viewer.
"""

let mcpTools: [[String: Any]] = [
    ["name": "lantern_open", "description": "Open markdown file(s) or a folder of .md files in the Lantern viewer. Launches Lantern if it is not running. Files update live as they change.",
     "inputSchema": ["type": "object", "required": ["paths"], "properties": [
        "paths": ["type": "array", "items": ["type": "string"], "description": "Absolute paths to .md files or folders"],
        "mode": ["type": "string", "enum": ["pane", "window"], "description": "pane = overlay on the front Ghostty window (default); window = normal window"],
        "width": ["type": "integer", "minimum": 10, "maximum": 90, "description": "Pane width in percent of the Ghostty window (default 40)"],
        "side": ["type": "string", "enum": ["left", "right"], "description": "Which side the pane covers (default right)"],
        "focus": ["type": "boolean", "description": "Bring the viewer to the front (default false)"]]]],
    ["name": "lantern_close", "description": "Close one open file, or the whole viewer when no path is given.",
     "inputSchema": ["type": "object", "properties": ["path": ["type": "string", "description": "Absolute path of the file to close; omit to close the viewer"]]]],
    ["name": "lantern_switch", "description": "Show a different already-open file (tab).",
     "inputSchema": ["type": "object", "required": ["target"], "properties": ["target": ["type": "string", "description": "Absolute path, 1-based tab index, or part of the file name"]]]],
    ["name": "lantern_list", "description": "List the files currently open in Lantern (the active one is marked).",
     "inputSchema": ["type": "object", "properties": [String: Any]()]],
    ["name": "lantern_layout", "description": "Resize the pane: set its width (percent of the Ghostty window) and/or which side it covers. Saved for next time.",
     "inputSchema": ["type": "object", "properties": [
        "width": ["type": "integer", "minimum": 10, "maximum": 90],
        "side": ["type": "string", "enum": ["left", "right"]]]]],
    ["name": "lantern_screenshot", "description": "Save a PNG screenshot of the viewer and return its path.",
     "inputSchema": ["type": "object", "properties": ["out": ["type": "string", "description": "Output path (default /tmp/lantern.png)"]]]],
]

func mcpCall(_ name: String, _ a: [String: Any]) -> (String, Bool) {
    func res(_ r: [String: Any], _ ok: String) -> (String, Bool) {
        if let e = r["error"] as? String { return (e, true) }
        return (r["message"] as? String ?? ok, false)
    }
    switch name {
    case "lantern_open":
        guard let paths = a["paths"] as? [String], !paths.isEmpty else { return ("paths is required", true) }
        var req: [String: Any] = ["cmd": "open", "paths": paths.map { Store.resolve($0) }, "focus": a["focus"] as? Bool ?? false]
        if let m = a["mode"] as? String { req["openIn"] = m }
        if let w = a["width"] { req["width"] = "\(w)" }
        if let s = a["side"] as? String { req["side"] = s }
        return res(request(req), "opened")
    case "lantern_close":
        return res(request(["cmd": "close", "path": (a["path"] as? String).map { Store.resolve($0) } ?? ""], launch: false), "closed")
    case "lantern_switch":
        guard let t = a["target"] as? String else { return ("target is required", true) }
        return res(request(["cmd": "switch", "target": FileManager.default.fileExists(atPath: t) ? Store.resolve(t) : t], launch: false), "ok")
    case "lantern_list":
        let r = request(["cmd": "list"], launch: false)
        if let e = r["error"] as? String { return (e, true) }
        let ps = r["plans"] as? [[String: Any]] ?? []
        return (ps.isEmpty ? "nothing open" : ps.map { "\($0["active"] as? Bool == true ? "* " : "  ")\($0["path"] as? String ?? "")" }.joined(separator: "\n"), false)
    case "lantern_layout":
        var req: [String: Any] = ["cmd": "width"]
        if let w = a["width"] as? Int { guard (10...90).contains(w) else { return ("width must be 10-90", true) }; req["value"] = w }
        if let s = a["side"] as? String { guard s == "left" || s == "right" else { return ("side must be left or right", true) }; req["side"] = s }
        return res(request(req, launch: false), "ok")
    case "lantern_screenshot":
        let out = a["out"] as? String ?? "/tmp/lantern.png"
        let r = request(["cmd": "snapshot", "out": out], launch: false)
        if let e = r["error"] as? String { return (e, true) }
        return ("saved \(out)", false)
    default: return ("unknown tool \(name)", true)
    }
}

func runMCP() -> Never {
    softErrors = true
    func send(_ o: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: o), let s = String(data: d, encoding: .utf8) else { return }
        print(s); fflush(stdout)
    }
    while let line = readLine() {
        guard let d = line.data(using: .utf8), let m = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
        let id = m["id"], method = m["method"] as? String ?? ""
        guard let rid = id else { continue }   // notifications (e.g. notifications/initialized) get no reply
        switch method {
        case "initialize":
            let want = (m["params"] as? [String: Any])?["protocolVersion"] as? String ?? "2025-03-26"
            send(["jsonrpc": "2.0", "id": rid, "result": ["protocolVersion": want, "capabilities": ["tools": [String: Any]()],
                                                          "serverInfo": ["name": "lantern", "version": "1.0.0"], "instructions": mcpInstructions]])
        case "ping": send(["jsonrpc": "2.0", "id": rid, "result": [String: Any]()])
        case "tools/list": send(["jsonrpc": "2.0", "id": rid, "result": ["tools": mcpTools]])
        case "tools/call":
            let p = m["params"] as? [String: Any] ?? [:]
            let (text, isErr) = mcpCall(p["name"] as? String ?? "", p["arguments"] as? [String: Any] ?? [:])
            send(["jsonrpc": "2.0", "id": rid, "result": ["content": [["type": "text", "text": text]], "isError": isErr]])
        default: send(["jsonrpc": "2.0", "id": rid, "error": ["code": -32601, "message": "method not found: \(method)"]])
        }
    }
    exit(0)
}

// MARK: commands
var args = Array(CommandLine.arguments.dropFirst())
guard let first = args.first else { print(usage); exit(0) }
let known: Set<String> = ["mcp", "open", "close", "switch", "width", "list", "snapshot", "eval", "help", "--help", "-h"]
var cmd = "open"
if known.contains(first) { cmd = first; args.removeFirst() }

func flag(_ n: String) -> Bool { if let i = args.firstIndex(of: n) { args.remove(at: i); return true }; return false }
func opt(_ n: String) -> String? {
    guard let i = args.firstIndex(of: n), i + 1 < args.count else { return nil }
    let v = args[i + 1]; args.removeSubrange(i...(i + 1)); return v
}

switch cmd {
case "mcp": runMCP()
case "help", "--help", "-h": print(usage)

case "open":
    var req: [String: Any] = ["cmd": "open"]
    if flag("--window") { req["openIn"] = "window" }
    if flag("--pane") { req["openIn"] = "pane" }
    if let w = opt("--width") { req["width"] = w }
    if let s = opt("--side") { req["side"] = s }
    if flag("--lite") { req["view"] = "lite" }
    if flag("--full") { req["view"] = "full" }
    req["focus"] = flag("--focus")
    let wantSplit = flag("--split")
    if args.isEmpty { die("usage: lantern open <file|dir>...") }
    req["paths"] = args.map { Store.resolve($0) }
    if wantSplit { ghosttySplit() }
    let r = request(req)
    if let e = r["error"] as? String { die(e) }
    print(r["message"] as? String ?? "ok")

case "close":
    let r = request(["cmd": "close", "path": args.first.map { Store.resolve($0) } ?? ""], launch: false)
    if let e = r["error"] as? String { die(e) }
    print(r["message"] as? String ?? "closed")

case "switch":
    guard let t = args.first else { die("usage: lantern switch <file|index|name>") }
    let r = request(["cmd": "switch", "target": FileManager.default.fileExists(atPath: t) ? Store.resolve(t) : t], launch: false)
    if let e = r["error"] as? String { die(e) }
    print(r["message"] as? String ?? "ok")

case "width":
    guard let w = args.first, let n = Int(w), (10...90).contains(n) else { die("usage: lantern width <10-90>") }
    let r = request(["cmd": "width", "value": n], launch: false)
    if let e = r["error"] as? String { die(e) }
    print("width \(n)%")

case "list":
    let r = request(["cmd": "list"], launch: false)
    if let e = r["error"] as? String { die(e) }
    for p in (r["plans"] as? [[String: Any]] ?? []) {
        print("\(p["active"] as? Bool == true ? "*" : " ") \(p["path"] as? String ?? "")")
    }

case "snapshot":
    guard let out = args.first else { die("usage: lantern snapshot <out.png>") }
    let r = request(["cmd": "snapshot", "out": Store.resolve(out)], launch: false, timeout: 30)
    if let e = r["error"] as? String { die(e) }
    print(r["message"] as? String ?? "saved")

case "eval":
    guard let js = args.first else { die("usage: lantern eval <js>") }
    let r = request(["cmd": "eval", "js": js], launch: false, timeout: 30)
    if let e = r["error"] as? String { die(e) }
    print(r["result"] as? String ?? "")

default: print(usage)
}
