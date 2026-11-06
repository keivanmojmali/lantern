import AppKit

/// Resolves `file.ts:123` references found in plans and opens them in an editor.
enum Editor {
    static func resolve(_ ref: String, planPath: String) -> (String, Int?)? {
        var name = ref; var line: Int?
        if let r = ref.range(of: #":(\d+)(-\d+)?$"#, options: .regularExpression) {
            let tail = ref[r].dropFirst()
            line = Int(tail.split(separator: "-").first ?? "")
            name = String(ref[ref.startIndex..<r.lowerBound])
        }
        let fm = FileManager.default
        if name.hasPrefix("/") { return fm.fileExists(atPath: name) ? (name, line) : nil }
        var dir = (planPath as NSString).deletingLastPathComponent
        for _ in 0..<8 {
            let cand = dir + "/" + name
            if fm.fileExists(atPath: cand) { return (cand, line) }
            for sub in ["src", "Sources", "app", "lib"] where fm.fileExists(atPath: dir + "/" + sub + "/" + name) { return (dir + "/" + sub + "/" + name, line) }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { break }
            dir = parent
        }
        return nil
    }

    static func open(path: String, line: Int?) {
        let template = SettingsDB.shared.get("editor")
        func sh(_ cmd: String) { let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = ["-lc", cmd]; try? p.run() }
        if !template.isEmpty {
            sh(template.replacingOccurrences(of: "{path}", with: "'\(path)'").replacingOccurrences(of: "{line}", with: String(line ?? 1)))
            return
        }
        for code in ["/opt/homebrew/bin/code", "/usr/local/bin/code"] where FileManager.default.isExecutableFile(atPath: code) {
            let p = Process(); p.executableURL = URL(fileURLWithPath: code); p.arguments = ["-g", "\(path):\(line ?? 1)"]; try? p.run(); return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}
