import AppKit
import WebKit

final class Controller: NSObject, WKScriptMessageHandler, WKNavigationDelegate, NSWindowDelegate {
    struct Plan {
        var path: String
        var content = ""
        var hash = ""
        var mtime = Date.distantPast
        var size = 0
        var missing = false
        var folder: String?
        var pendingNew = false
    }

    let isTest = ProcessInfo.processInfo.environment["LANTERN_TEST"] != nil
    var window: LWindow!
    var web: LWebView!
    var ready = false
    var queued: [String] = []
    var plans: [String: Plan] = [:]
    var order: [String] = []
    var activePath: String?
    var folders: [String: Set<String>] = [:]     // folder -> known files
    var dismissed = Set<String>()
    var overlay: PaneOverlay?
    var paneMode = false
    var view = "full"
    var tick = 0
    var scanning = false
    let io = DispatchQueue(label: "lantern.io")   // all file reads happen here: a macOS privacy prompt must never freeze the UI
    var timer: Timer?
    var settings: [String: String] { SettingsDB.shared.all() }

    override init() {
        super.init()
        buildWindow()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.watch() }
    }

    // MARK: window + webview
    func buildWindow() {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(self, name: "lantern")
        cfg.setURLSchemeHandler(AssetScheme(), forURLScheme: "lantern-asset")
        cfg.preferences.setValue(true, forKey: "developerExtrasEnabled")
        web = LWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        web.registerForDraggedTypes([.fileURL])
        web.onDrop = { [weak self] paths in self?.open(paths: paths, opts: [:], focus: true) }
        window = LWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 780),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        window.contentView = web
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 320, height: 300)
        window.setFrameAutosaveName(isTest ? "LanternTest" : "LanternMain")
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    func styleForWindowMode() {
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovable = true
        window.isMovableByWindowBackground = true
        window.hasShadow = true
    }
    func styleForPane() {
        window.styleMask = [.borderless, .resizable]
        window.hasShadow = false
        window.isMovable = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        pushSettings()
        js("Lantern.setView(\(q(view)))")
        for p in order where plans[p]?.hash.isEmpty == false { push(p, isNew: false) }
        if let a = activePath { js("Lantern.activate(\(q(a)))") }
        queued.forEach { web.evaluateJavaScript($0) }; queued = []
    }

    // MARK: JS bridge
    func q(_ s: String) -> String { jsonString(s) }
    func jsonString(_ o: Any) -> String {
        if let s = o as? String {
            let d = try! JSONSerialization.data(withJSONObject: [s]); let t = String(data: d, encoding: .utf8)!
            return String(t.dropFirst().dropLast())
        }
        let d = (try? JSONSerialization.data(withJSONObject: o)) ?? Data("null".utf8)
        return String(data: d, encoding: .utf8)!
    }
    func js(_ code: String) {
        if ready { web.evaluateJavaScript(code, completionHandler: nil) } else { queued.append(code) }
    }
    func pushSettings() { js("Lantern.setSettings(\(jsonString(settings)))") }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let s = m.body as? String, let d = s.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let t = msg["t"] as? String else { return }
        let path = msg["path"] as? String ?? ""
        switch t {
        case "closePlan": closePlan(path)
        case "closeAll": closeAll()
        case "openRef":
            if let ref = msg["ref"] as? String {
                if let (f, line) = Editor.resolve(ref, planPath: path) { Editor.open(path: f, line: line) }
                else { js("Lantern.toast(\(q("Can't find " + ref)))") }
            }
        case "copy":
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(msg["text"] as? String ?? "", forType: .string)
        case "openDialog": openDialog()
        case "openURL":
            let u = msg["url"] as? String ?? ""
            if u.hasPrefix("http://") || u.hasPrefix("https://") || u.hasPrefix("mailto:") { if let url = URL(string: u) { NSWorkspace.shared.open(url) } }
            else {
                let rel = u.components(separatedBy: "#")[0].removingPercentEncoding ?? u
                let abs = rel.hasPrefix("/") ? rel : ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(rel)
                if rel.lowercased().hasSuffix(".md") { open(paths: [abs], opts: ["openIn": paneMode ? "pane" : "window"], focus: false) }
            }
        case "focusTerminal":
            guard paneMode else { return }
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.mitchellh.ghostty").first?.activate(options: [])
        case "active": activePath = path; updateTitle()
        default: break
        }
    }

    func applySetting(_ k: String, _ v: String) {
        SettingsDB.shared.set(k, v)
        if k == "appearance" { applyAppearance() }
        if k == "width" || k == "side" { overlay?.tick() }
        pushSettings()
    }
    func applyAppearance() {
        switch settings["appearance"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    // MARK: opening
    func openDialog() {
        let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.canChooseDirectories = true
        if p.runModal() == .OK { open(paths: p.urls.map { $0.path }, opts: [:], focus: true) }
    }

    func open(paths: [String], opts: [String: Any], focus: Bool, done: @escaping (String, Bool) -> Void = { _, _ in }) {
        io.async { [self] in
            var files: [String] = []; var dirs: [(String, [String])] = []
            for raw in paths {
                let path = Store.resolve(raw)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { continue }
                if isDir.boolValue { dirs.append((path, scanFolder(path))) } else { files.append(path) }
            }
            DispatchQueue.main.async {
                if files.isEmpty && dirs.isEmpty { return done("not found or not readable: \(paths.joined(separator: ", "))", true) }
                done(self.finishOpen(files: files, dirs: dirs, opts: opts, focus: focus), false)
            }
        }
    }

    func finishOpen(files: [String], dirs: [(String, [String])], opts: [String: Any], focus: Bool) -> String {
        var firstNew: String?
        for (dir, fs) in dirs {
            folders[dir] = Set(fs)
            for f in fs { dismissed.remove(f); if addPlan(f, folder: dir, isNew: false), firstNew == nil { firstNew = f } }
        }
        for f in files { dismissed.remove(f); addPlan(f, folder: nil, isNew: false); firstNew = f }
        guard let activate = firstNew ?? files.first ?? order.first, !order.isEmpty else { return "nothing to open (path not found or not readable)" }
        activePath = activate
        js("Lantern.activate(\(q(activate)))")

        if let w = opts["width"] as? String ?? (opts["width"] as? Int).map(String.init) { SettingsDB.shared.set("width", w); pushSettings() }
        if let s = opts["side"] as? String { SettingsDB.shared.set("side", s); pushSettings() }
        var wantPane = (opts["openIn"] as? String ?? settings["openIn"]) == "pane"
        let ghostty = PaneOverlay(window: window, widthPct: { 40 }, side: { "right" }).ghosttyWindow() != nil
        var note = ""
        if wantPane && !ghostty && !isTest { wantPane = false; note = " (no Ghostty window found, opened as a window)" }
        if let v = opts["view"] as? String { view = v } else { view = wantPane ? "lite" : "full" }
        js("Lantern.setView(\(q(view)))")
        show(pane: wantPane, focus: opts["focus"] as? Bool ?? focus)
        updateTitle()
        return "opened \(files.count + dirs.count) path(s) — \(wantPane ? "pane \(settings["width"] ?? "40")%" : "window")\(note)"
    }

    func show(pane: Bool, focus: Bool) {
        paneMode = pane
        js("Lantern.setChrome(\(q(pane ? "pane" : "window")))")
        if pane {
            styleForPane()
            if isTest {
                overlay?.stop(); overlay = nil
                window.setFrame(NSRect(x: -4000, y: 100, width: 520, height: 780), display: true)
            } else {
                if overlay == nil {
                    overlay = PaneOverlay(window: window, widthPct: { [weak self] in Double(self?.settings["width"] ?? "40") ?? 40 },
                                          side: { [weak self] in self?.settings["side"] ?? "right" })
                }
                overlay?.start()
            }
        } else {
            overlay?.stop(); overlay = nil
            styleForWindowMode()
            if isTest { window.setFrame(NSRect(x: -4000, y: 100, width: 1000, height: 780), display: true) }
            else if !window.isVisible { window.center() }
        }
        if focus && !isTest { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
        else if !pane { window.orderFrontRegardless() }
        else if isTest { window.orderFrontRegardless() }
    }

    func updateTitle() {
        window.title = "Lantern" + (activePath.map { " — " + ($0 as NSString).lastPathComponent } ?? "")
    }

    // MARK: plans
    func scanFolder(_ dir: String, depth: Int = 0) -> [String] {
        guard depth < 3, let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        var out = [String]()
        for n in items.sorted() where !n.hasPrefix(".") && n != "node_modules" {
            let full = dir + "/" + n
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: full, isDirectory: &isDir)
            if isDir.boolValue { out += scanFolder(full, depth: depth + 1) }
            else if ["md", "markdown"].contains((n as NSString).pathExtension.lowercased()) { out.append(full) }
        }
        return out
    }

    /// Registers a plan; its content is loaded by the next watch() tick (off the main thread).
    @discardableResult
    func addPlan(_ path: String, folder: String?, isNew: Bool) -> Bool {
        if plans[path] != nil { return false }
        var p = Plan(path: path, folder: folder); p.pendingNew = isNew
        plans[path] = p; order.append(path)
        return true
    }

    struct FileData { var content: String; var mtime: Date; var size: Int }
    static func readFile(_ path: String) -> FileData? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path), let data = fm.contents(atPath: path) else { return nil }
        return FileData(content: String(decoding: data, as: UTF8.self), mtime: attrs[.modificationDate] as? Date ?? Date(), size: data.count)
    }

    func push(_ path: String, isNew: Bool) {
        guard let p = plans[path] else { return }
        let dict: [String: Any] = [
            "path": path, "name": (path as NSString).lastPathComponent, "content": p.content,
            "missing": p.missing, "isNew": isNew, "folder": p.folder ?? "",
        ]
        js("Lantern.update(\(jsonString(dict)))")
    }

    func watch() {
        tick += 1
        guard !scanning else { return }
        scanning = true
        let known = order.compactMap { plans[$0] }.map { ($0.path, $0.mtime, $0.size, $0.missing) }
        let folderSnapshot = tick % 5 == 0 ? folders : [:]
        io.async { [self] in
            let fm = FileManager.default
            var updates: [(String, FileData?)] = []
            for (path, mtime, size, missing) in known {
                if let attrs = try? fm.attributesOfItem(atPath: path) {
                    let m = attrs[.modificationDate] as? Date ?? .distantPast
                    let sz = (attrs[.size] as? NSNumber)?.intValue ?? 0
                    if m != mtime || sz != size || missing { updates.append((path, Controller.readFile(path))) }
                } else if !missing { updates.append((path, nil)) }
            }
            var found: [(String, String)] = []
            for (dir, seen) in folderSnapshot { for f in scanFolder(dir) where !seen.contains(f) { found.append((f, dir)) } }
            DispatchQueue.main.async {
                for (path, data) in updates {
                    guard var p = self.plans[path] else { continue }
                    if let d = data {
                        let old = p.hash, wasMissing = p.missing
                        p.content = d.content; p.mtime = d.mtime; p.size = d.size; p.missing = false; p.hash = Store.hash(d.content)
                        let isNew = p.pendingNew; p.pendingNew = false
                        self.plans[path] = p
                        if p.hash != old || wasMissing {
                            self.push(path, isNew: isNew)
                        }
                    } else {
                        p.missing = true; self.plans[path] = p; self.push(path, isNew: false)
                    }
                }
                for (f, dir) in found {
                    self.folders[dir]?.insert(f)
                    if !self.dismissed.contains(f) { self.addPlan(f, folder: dir, isNew: true) }
                }
                self.scanning = false
            }
        }
    }

    func closePlan(_ path: String) {
        guard plans[path] != nil else { return }
        plans[path] = nil; order.removeAll { $0 == path }; dismissed.insert(path)
        js("Lantern.remove(\(q(path)))")
        if activePath == path { activePath = order.first }
        updateTitle()
        if order.isEmpty { closeAll() }
    }

    func closeAll() {
        overlay?.stop(); overlay = nil
        for path in order { js("Lantern.remove(\(q(path)))") }
        window.orderOut(nil)
        plans = [:]; order = []; folders = [:]; activePath = nil
        if !isTest { NSApp.terminate(nil) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { closeAll(); return false }

    // MARK: IPC
    func handle(_ req: [String: Any], reply: @escaping IPCServer.Reply) {
        switch req["cmd"] as? String ?? "" {
        case "open":
            open(paths: req["paths"] as? [String] ?? [], opts: req, focus: req["focus"] as? Bool ?? false) { msg, failed in reply(failed ? ["error": msg] : ["message": msg]) }
        case "close":
            if let p = req["path"] as? String, !p.isEmpty {
                guard plans[p] != nil else { return reply(["error": "not open: \(p)"]) }
                closePlan(p); reply(["message": "closed \((p as NSString).lastPathComponent)"])
            } else { reply(["message": "closed"]); DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.closeAll() } }
        case "switch":
            let t = req["target"] as? String ?? ""
            var hit: String?
            if let i = Int(t), i >= 1, i <= order.count { hit = order[i - 1] }
            else if plans[t] != nil { hit = t }
            else { hit = order.first { ($0 as NSString).lastPathComponent.localizedCaseInsensitiveContains(t) } }
            guard let h = hit else { return reply(["error": "no such plan: \(t)"]) }
            activePath = h; js("Lantern.activate(\(q(h)))"); updateTitle(); reply(["message": "switched to \((h as NSString).lastPathComponent)"])
        case "width":
            if let v = req["value"] { applySetting("width", "\(v)") }
            if let sd = req["side"] as? String { applySetting("side", sd) }
            reply(["message": "pane: \(settings["width"] ?? "40")% on the \(settings["side"] ?? "right")"])
        case "list":
            reply(["plans": order.map { p -> [String: Any] in
                return ["path": p, "active": p == activePath]
            }])
        case "snapshot":
            let out = req["out"] as? String ?? "/tmp/lantern.png"
            web.takeSnapshot(with: nil) { img, err in
                guard let img = img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else { return reply(["error": err?.localizedDescription ?? "snapshot failed"]) }
                try? png.write(to: URL(fileURLWithPath: out))
                reply(["message": "saved \(out) (\(Int(img.size.width))x\(Int(img.size.height)))"])
            }
        case "eval":
            guard isTest else { return reply(["error": "eval is only available with LANTERN_TEST=1"]) }
            web.evaluateJavaScript(req["js"] as? String ?? "") { r, e in
                if let e = e { reply(["error": "\(e)"]) } else { reply(["result": r.map { "\($0)" } ?? ""]) }
            }
        default: reply(["error": "unknown command"])
        }
    }

    func jsCmd(_ c: String) { js("Lantern.cmd(\(q(c)))") }
}
