import Foundation
import Darwin

// lantern — control the Lantern plan viewer.

let usage = """
lantern — live plan viewer for your terminal workflow

  lantern <file.md|dir>...          open plans (same as `lantern open`)
  lantern open <file|dir>... [--focus]
  lantern close [file]              close one plan, or the whole viewer when no file is given
  lantern switch <file|index|name>  show another open plan
  lantern window [--width N] [--height N] [--x N] [--y N] [--center] [--minimize|--restore|--fullscreen]
                                    resize / move Lantern's own window (x,y from top-left of the screen)
  lantern goto <target> [--file F] [--focus]
                                    scroll the viewer to a heading, text snippet or answer-box id
  lantern answers [file] [--wait N] print what the user typed into the document's answer boxes
                                    (--wait N: block up to N seconds until every box is sent)
  lantern comments [file] [--wait N] print the comments the user attached to highlighted text
                                    (--wait N: block up to N seconds until the user presses Done)
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
    if env["LANTERN_TEST"] != nil { args.append("-n") }   // tests: new instance, never poke the user's real running Lantern
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

// MARK: MCP server (newline-delimited JSON-RPC 2.0 over stdio)
let mcpInstructions = """
Lantern is a lean markdown viewer that shows your plans live in its own window. It is view-only: the user reads, you keep working.
- When you write or substantially update a plan/spec/design doc (a .md file), call lantern_open with its absolute path so the user can read it rendered. Opening a folder shows every .md in it as tabs.
- Edits you make to an open file appear live (changed blocks glow), so do NOT re-open after editing. Just keep writing the file.
- Use lantern_switch to bring a different open file to the front, lantern_close when the doc is no longer relevant, lantern_list to see what is open.
- Use lantern_window to resize, move, center, minimize or restore Lantern's own window if the user asks for more/less room or a different spot.
- To point the user at something, call lantern_goto with a heading, a text snippet or an answer id; the viewer scrolls there and pulses it. Set focus true only when you need their attention right now.
- To ask the user questions inside the document, put each one in a fenced block: ```answer q1 (newline) your question (newline) ```. The viewer shows it as a text box with a Send button. Open/refresh the doc, lantern_goto the first box, then read replies with lantern_answers (wait_seconds lets you block until they press Send). Answers are never written into the .md.
- The user can also highlight any text in the viewer and attach a comment (e.g. to decide an open question and move on), then press "Done" in the viewer or tell you they are done. Read those with lantern_comments: it returns each highlighted quote, its section and the comment. Treat the comments as the user's decisions, then update the doc accordingly. Use wait_seconds to block until they press Done.
- lantern_screenshot saves a PNG of the viewer if you need to check how something rendered.
- Do not steal focus: leave focus false unless the user asks to jump to the viewer.
"""

let mcpTools: [[String: Any]] = [
    ["name": "lantern_open", "description": "Open markdown file(s) or a folder of .md files in the Lantern viewer. Launches Lantern if it is not running. Files update live as they change.",
     "inputSchema": ["type": "object", "required": ["paths"], "properties": [
        "paths": ["type": "array", "items": ["type": "string"], "description": "Absolute paths to .md files or folders"],
        "focus": ["type": "boolean", "description": "Bring the viewer to the front (default false)"]]]],
    ["name": "lantern_close", "description": "Close one open file, or the whole viewer when no path is given.",
     "inputSchema": ["type": "object", "properties": ["path": ["type": "string", "description": "Absolute path of the file to close; omit to close the viewer"]]]],
    ["name": "lantern_switch", "description": "Show a different already-open file (tab).",
     "inputSchema": ["type": "object", "required": ["target"], "properties": ["target": ["type": "string", "description": "Absolute path, 1-based tab index, or part of the file name"]]]],
    ["name": "lantern_list", "description": "List the files currently open in Lantern (the active one is marked).",
     "inputSchema": ["type": "object", "properties": [String: Any]()]],
    ["name": "lantern_goto", "description": "Scroll the viewer to a place in a document so the user sees it (also switches to that tab). Use it when you want to point the user at something: a section, a diagram, a question. The spot pulses briefly.",
     "inputSchema": ["type": "object", "required": ["target"], "properties": [
        "target": ["type": "string", "description": "Heading text (e.g. \"Open questions\"), a snippet of text from the block, or an answer-box id"],
        "path": ["type": "string", "description": "Absolute path of the file; omit for the file currently shown"],
        "focus": ["type": "boolean", "description": "Also bring Lantern to the front (default false). Use true when you need the user's attention now."]]]],
    ["name": "lantern_answers", "description": "Read what the user typed into the answer boxes of the open document(s). Add a box by writing a fenced block ```answer <id>``` in the markdown with your question as the body. Returns each box's question, text, and whether the user pressed Send.",
     "inputSchema": ["type": "object", "properties": [
        "path": ["type": "string", "description": "Absolute path of the file; omit for all open files"],
        "wait_seconds": ["type": "integer", "minimum": 0, "maximum": 300, "description": "Block until every box has been sent, up to this many seconds (default 0 = return immediately)"]]]],
    ["name": "lantern_comments", "description": "Read the comments the user attached to highlighted text in the open document(s): the selected quote, the section it sits under, and their comment. Also says whether the user pressed Done (finished commenting). Comments are never written into the .md.",
     "inputSchema": ["type": "object", "properties": [
        "path": ["type": "string", "description": "Absolute path of the file; omit for all open files"],
        "wait_seconds": ["type": "integer", "minimum": 0, "maximum": 300, "description": "Block until the user presses Done, up to this many seconds (default 0 = return immediately)"]]]],
    ["name": "lantern_window", "description": "Resize and/or move Lantern's own window. Omitted fields stay unchanged; returns the resulting size and position.",
     "inputSchema": ["type": "object", "properties": [
        "width": ["type": "integer", "minimum": 320, "description": "Window width in points"],
        "height": ["type": "integer", "minimum": 300, "description": "Window height in points"],
        "x": ["type": "integer", "description": "Left edge, from the left of the main screen"],
        "y": ["type": "integer", "description": "Top edge, from the top of the main screen"],
        "center": ["type": "boolean", "description": "Center the window on screen"],
        "state": ["type": "string", "enum": ["minimize", "restore", "fullscreen"]]]]],
    ["name": "lantern_screenshot", "description": "Save a PNG screenshot of the viewer and return its path.",
     "inputSchema": ["type": "object", "properties": ["out": ["type": "string", "description": "Output path (default /tmp/lantern.png)"]]]],
]

/// Fetch answer boxes; with wait > 0, poll until every box has been sent (or time runs out).
func fetchAnswers(path: String, wait: Double) -> (String, Bool) {
    let deadline = Date().addingTimeInterval(wait)
    while true {
        let r = request(["cmd": "answers", "path": path], launch: false)
        if let e = r["error"] as? String { return (e, true) }
        let boxes = r["answers"] as? [[String: Any]] ?? []
        let pending = boxes.contains { $0["sent"] as? Bool != true }
        if boxes.isEmpty || !pending || Date() >= deadline {
            if boxes.isEmpty { return ("no answer boxes in the open document(s). Add a ```answer <id>``` fenced block with your question inside.", false) }
            var out = ""
            for b in boxes {
                let sent = b["sent"] as? Bool == true, text = b["text"] as? String ?? ""
                let state = sent ? "sent" : text.isEmpty ? "not answered yet" : "draft, not sent yet"
                out += "[\(b["id"] as? String ?? "")] \(b["question"] as? String ?? "")\n  (\(state))\n"
                if !text.isEmpty { out += text.split(separator: "\n", omittingEmptySubsequences: false).map { "  > \($0)" }.joined(separator: "\n") + "\n" }
                out += "\n"
            }
            return (out.trimmingCharacters(in: .whitespacesAndNewlines), false)
        }
        sleep(1)
    }
}

/// Fetch highlight comments; with wait > 0, poll until the user has pressed Done on every document that has comments.
func fetchComments(path: String, wait: Double) -> (String, Bool) {
    let deadline = Date().addingTimeInterval(wait)
    while true {
        let r = request(["cmd": "comments", "path": path], launch: false)
        if let e = r["error"] as? String { return (e, true) }
        let docs = (r["comments"] as? [[String: Any]] ?? []).filter { !($0["notes"] as? [[String: Any]] ?? []).isEmpty }
        let pending = docs.isEmpty || docs.contains { $0["submitted"] as? Bool != true }
        if !pending || Date() >= deadline {
            if docs.isEmpty { return ("no comments yet. The user can highlight text in the viewer and add a comment.", false) }
            var out = ""
            for d in docs {
                let notes = d["notes"] as? [[String: Any]] ?? []
                let done = d["submitted"] as? Bool == true
                out += "\(d["path"] as? String ?? "") — \(notes.count) comment\(notes.count == 1 ? "" : "s"), " + (done ? "user pressed Done" : "user has NOT pressed Done yet (may still be commenting)") + "\n"
                for (i, n) in notes.enumerated() {
                    let sec = (n["section"] as? String ?? "").isEmpty ? "" : " [§ \(n["section"] as? String ?? "")]"
                    out += "\n\(i + 1).\(sec) on: \"\(n["quote"] as? String ?? "")\"\n"
                    out += (n["text"] as? String ?? "").split(separator: "\n", omittingEmptySubsequences: false).map { "   > \($0)" }.joined(separator: "\n") + "\n"
                }
                out += "\n"
            }
            return (out.trimmingCharacters(in: .whitespacesAndNewlines), false)
        }
        sleep(1)
    }
}

func mcpCall(_ name: String, _ a: [String: Any]) -> (String, Bool) {
    func res(_ r: [String: Any], _ ok: String) -> (String, Bool) {
        if let e = r["error"] as? String { return (e, true) }
        return (r["message"] as? String ?? ok, false)
    }
    switch name {
    case "lantern_open":
        guard let paths = a["paths"] as? [String], !paths.isEmpty else { return ("paths is required", true) }
        var req: [String: Any] = ["cmd": "open", "paths": paths.map { Store.resolve($0) }, "focus": a["focus"] as? Bool ?? false]
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
    case "lantern_goto":
        guard let t = a["target"] as? String, !t.isEmpty else { return ("target is required", true) }
        return res(request(["cmd": "goto", "target": t, "path": (a["path"] as? String).map { Store.resolve($0) } ?? "", "focus": a["focus"] as? Bool ?? false], launch: false, timeout: 20), "ok")
    case "lantern_answers":
        let wait = min(max((a["wait_seconds"] as? NSNumber)?.doubleValue ?? 0, 0), 300)
        return fetchAnswers(path: (a["path"] as? String).map { Store.resolve($0) } ?? "", wait: wait)
    case "lantern_comments":
        let wait = min(max((a["wait_seconds"] as? NSNumber)?.doubleValue ?? 0, 0), 300)
        return fetchComments(path: (a["path"] as? String).map { Store.resolve($0) } ?? "", wait: wait)
    case "lantern_window":
        var req: [String: Any] = ["cmd": "window"]
        for k in ["width", "height", "x", "y", "center", "state"] { if let v = a[k] { req[k] = v } }
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
let known: Set<String> = ["goto", "answers", "comments", "mcp", "open", "close", "switch", "window", "list", "snapshot", "eval", "help", "--help", "-h"]
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
    req["focus"] = flag("--focus")
    if args.isEmpty { die("usage: lantern open <file|dir>...") }
    req["paths"] = args.map { Store.resolve($0) }
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

case "window":
    var req: [String: Any] = ["cmd": "window"]
    for k in ["width", "height", "x", "y"] {
        if let v = opt("--" + k) { guard let n = Int(v) else { die("--\(k) needs a number") }; req[k] = n }
    }
    if flag("--center") { req["center"] = true }
    if flag("--minimize") { req["state"] = "minimize" }
    if flag("--restore") { req["state"] = "restore" }
    if flag("--fullscreen") { req["state"] = "fullscreen" }
    let r = request(req, launch: false)
    if let e = r["error"] as? String { die(e) }
    print(r["message"] as? String ?? "ok")

case "goto":
    let focus = flag("--focus"), file = opt("--file").map { Store.resolve($0) } ?? ""
    guard !args.isEmpty else { die("usage: lantern goto <heading|text|answer-id> [--file F] [--focus]") }
    let r = request(["cmd": "goto", "target": args.joined(separator: " "), "path": file, "focus": focus], launch: false, timeout: 20)
    if let e = r["error"] as? String { die(e) }
    print(r["message"] as? String ?? "ok")

case "answers":
    let wait = opt("--wait").flatMap { Double($0) } ?? 0
    let (text, isErr) = fetchAnswers(path: args.first.map { Store.resolve($0) } ?? "", wait: wait)
    if isErr { die(text) }
    print(text)

case "comments":
    let wait = opt("--wait").flatMap { Double($0) } ?? 0
    let (text, isErr) = fetchComments(path: args.first.map { Store.resolve($0) } ?? "", wait: wait)
    if isErr { die(text) }
    print(text)

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
