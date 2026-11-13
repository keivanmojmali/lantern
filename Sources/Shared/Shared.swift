import Foundation
import SQLite3
import CryptoKit

// MARK: Paths
enum LPaths {
    static var home: String { ProcessInfo.processInfo.environment["LANTERN_HOME"] ?? (NSHomeDirectory() + "/.lantern") }
    static var socket: String { home + "/lantern.sock" }
    static var settingsDB: String { home + "/settings.db" }
}

// MARK: Settings (local-only SQLite)
final class SettingsDB {
    static let shared = SettingsDB()
    static let defaults: [String: String] = [
        "appearance": "system",   // system | light | dark
        "tabs": "side",           // side | top
        "vim": "1",
        "dataFolder": "",         // empty = ~/.lantern
        "editor": "",             // optional template, e.g. code -g {path}:{line}
    ]
    private var db: OpaquePointer?
    init() {
        try? FileManager.default.createDirectory(atPath: LPaths.home, withIntermediateDirectories: true)
        sqlite3_open(LPaths.settingsDB, &db)
        sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)", nil, nil, nil)
    }
    func all() -> [String: String] {
        var out = SettingsDB.defaults
        var st: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT key, value FROM settings", -1, &st, nil) == SQLITE_OK {
            while sqlite3_step(st) == SQLITE_ROW {
                if let k = sqlite3_column_text(st, 0), let v = sqlite3_column_text(st, 1) {
                    out[String(cString: k)] = String(cString: v)
                }
            }
        }
        sqlite3_finalize(st)
        return out
    }
    func get(_ k: String) -> String { all()[k] ?? "" }
    func set(_ k: String, _ v: String) {
        var st: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT INTO settings(key,value) VALUES(?1,?2) ON CONFLICT(key) DO UPDATE SET value=?2", -1, &st, nil) == SQLITE_OK {
            let T = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(st, 1, k, -1, T)
            sqlite3_bind_text(st, 2, v, -1, T)
            sqlite3_step(st)
        }
        sqlite3_finalize(st)
    }
}

// MARK: Sidecar model (never touches the .md)
struct Comment: Codable {
    var id: String
    var kind: String        // note | ok | reject | question
    var quote: String
    var text: String
    var section: String
    var block: Int?
    var created: Double
}
struct PlanState: Codable {
    var path: String
    var status: String = "pending"   // pending | approved | changes
    var decidedHash: String = ""
    var comments: [Comment] = []
}
/// What the user typed into an ```answer``` box in the viewer. Lives next to the plan, never inside the .md.
struct Answer: Codable { var text: String; var sent: Bool; var ts: Double }
struct AnswerBox { var id: String; var label: String }
/// A comment the user attached to highlighted text. `quote` is the rendered text they selected, `before` the text just ahead of it
/// (disambiguates repeats), `section` the heading it sits under. `submitted` means the user pressed "Done" in the viewer.
struct Note: Codable { var id: String; var quote: String; var before: String; var section: String; var text: String; var ts: Double }
struct NoteSet: Codable {
    var notes: [Note] = []
    var submitted = false
    var json: [String: Any] {
        let arr = (try? JSONEncoder().encode(notes)).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? []
        return ["notes": arr, "submitted": submitted]
    }
}

struct Snapshot: Codable { var ts: Double; var hash: String; var content: String }

enum Store {
    static func resolve(_ p: String) -> String {
        let expanded = (p as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        return url.standardizedFileURL.resolvingSymlinksInPath().path
    }
    static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
    static func key(_ path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
    static var dir: String {
        let f = SettingsDB.shared.get("dataFolder")
        let base = f.isEmpty ? LPaths.home : (f as NSString).expandingTildeInPath
        let d = base + "/data"
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }
    static func load(_ path: String) -> PlanState {
        let f = dir + "/" + key(path) + ".json"
        if let d = FileManager.default.contents(atPath: f), let s = try? JSONDecoder().decode(PlanState.self, from: d) { return s }
        return PlanState(path: path)
    }
    static func save(_ s: PlanState) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(s) { try? d.write(to: URL(fileURLWithPath: dir + "/" + key(s.path) + ".json"), options: .atomic) }
    }
    /// A decision only counts for the exact content it was made on.
    static func effectiveStatus(_ s: PlanState, content: String) -> String {
        if s.status == "pending" { return "pending" }
        return s.decidedHash == hash(content) ? s.status : "pending"
    }
    static func statusLabel(_ s: String) -> String {
        switch s { case "approved": return "Approved"; case "changes": return "Changes requested"; default: return "Pending" }
    }
    static func format(_ s: PlanState, status: String) -> String {
        var out = "Plan: \(s.path)\nStatus: \(statusLabel(status))\n"
        let notes = s.comments
        if notes.isEmpty { return out + "No review notes.\n" }
        out += "Review notes (\(notes.count)):\n"
        for (i, c) in notes.enumerated() {
            let sec = c.section.isEmpty ? "" : " [§ \(c.section)]"
            switch c.kind {
            case "ok": out += "\(i + 1). ✓ approved section\(sec)\n"
            case "reject": out += "\(i + 1). ✗ rejected section\(sec)\n"
            case "question": out += "\(i + 1). ? question\(sec): \(c.text)\n"
            default:
                let q = c.quote.isEmpty ? "" : " on \"\(c.quote.prefix(160))\""
                out += "\(i + 1). note\(sec)\(q): \(c.text)\n"
            }
        }
        return out
    }
    // Answer boxes: ```answer <id>\n<question>\n``` fences in the markdown
    static func answerBoxes(_ content: String) -> [AnswerBox] {
        guard let re = try? NSRegularExpression(pattern: "^```answer[ \\t]+(\\S+)[ \\t]*\\n([\\s\\S]*?)^```", options: [.anchorsMatchLines]) else { return [] }
        let ns = content as NSString
        return re.matches(in: content, range: NSRange(location: 0, length: ns.length)).map {
            AnswerBox(id: ns.substring(with: $0.range(at: 1)), label: ns.substring(with: $0.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
    static func answersFile(_ path: String) -> String { dir + "/" + key(path) + ".answers.json" }
    static func loadAnswers(_ path: String) -> [String: Answer] {
        guard let d = FileManager.default.contents(atPath: answersFile(path)) else { return [:] }
        return (try? JSONDecoder().decode([String: Answer].self, from: d)) ?? [:]
    }
    static func saveAnswers(_ path: String, _ a: [String: Answer]) {
        if let d = try? JSONEncoder().encode(a) { try? d.write(to: URL(fileURLWithPath: answersFile(path)), options: .atomic) }
    }
    static func notesFile(_ path: String) -> String { dir + "/" + key(path) + ".comments.json" }
    static func loadNotes(_ path: String) -> NoteSet {
        guard let d = FileManager.default.contents(atPath: notesFile(path)) else { return NoteSet() }
        return (try? JSONDecoder().decode(NoteSet.self, from: d)) ?? NoteSet()
    }
    static func saveNotes(_ path: String, _ n: NoteSet) {
        if let d = try? JSONEncoder().encode(n) { try? d.write(to: URL(fileURLWithPath: notesFile(path)), options: .atomic) }
    }
    // History: last 50 snapshots
    static func histFile(_ path: String) -> String { dir + "/" + key(path) + ".history.json" }
    static func history(_ path: String) -> [Snapshot] {
        guard let d = FileManager.default.contents(atPath: histFile(path)) else { return [] }
        return (try? JSONDecoder().decode([Snapshot].self, from: d)) ?? []
    }
    static func snapshot(_ path: String, content: String) {
        var h = history(path)
        let hs = hash(content)
        if h.last?.hash == hs { return }
        h.append(Snapshot(ts: Date().timeIntervalSince1970, hash: hs, content: content))
        if h.count > 50 { h.removeFirst(h.count - 50) }
        if let d = try? JSONEncoder().encode(h) { try? d.write(to: URL(fileURLWithPath: histFile(path)), options: .atomic) }
    }
}
