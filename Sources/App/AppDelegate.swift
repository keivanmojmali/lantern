import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: Controller!
    var server: IPCServer!

    func applicationDidFinishLaunching(_ n: Notification) {
        let test = ProcessInfo.processInfo.environment["LANTERN_TEST"] != nil
        NSApp.setActivationPolicy(test ? .accessory : .regular)
        NSApp.applicationIconImage = Self.icon()
        controller = Controller()
        controller.applyAppearance()
        buildMenu()
        server = IPCServer { [weak self] req, reply in self?.controller.handle(req, reply: reply) }
        server.start()
    }
    func applicationWillTerminate(_ n: Notification) { server?.stop() }
    func application(_ app: NSApplication, open urls: [URL]) { controller.open(paths: urls.map { $0.path }, opts: [:], focus: true) }
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }

    @objc func openDoc() { controller.openDialog() }
    @objc func closePlan() { controller.jsCmd("closePlan") }

    func buildMenu() {
        let main = NSMenu()
        func add(_ menu: NSMenu, _ title: String, _ sel: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            it.keyEquivalentModifierMask = mods
            it.target = target ?? (sel.map { _ in self })
            menu.addItem(it)
        }
        func sub(_ title: String, _ build: (NSMenu) -> Void) {
            let item = NSMenuItem(); let m = NSMenu(title: title); build(m); item.submenu = m; main.addItem(item)
        }
        sub("Lantern") { m in
            add(m, "About Lantern", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp)
            m.addItem(.separator())
            add(m, "Hide Lantern", #selector(NSApplication.hide(_:)), "h", target: NSApp)
            add(m, "Quit Lantern", #selector(NSApplication.terminate(_:)), "q", target: NSApp)
        }
        sub("File") { m in
            add(m, "Open…", #selector(openDoc), "o")
            add(m, "Close Plan", #selector(closePlan), "w")
        }
        sub("Edit") { m in
            add(m, "Copy", #selector(NSText.copy(_:)), "c", target: nil)
            add(m, "Select All", #selector(NSText.selectAll(_:)), "a", target: nil)
        }
        NSApp.mainMenu = main
    }

    static func icon() -> NSImage {
        let s: CGFloat = 512
        return NSImage(size: NSSize(width: s, height: s), flipped: false) { r in
            NSColor(srgbRed: 0.094, green: 0.094, blue: 0.094, alpha: 1).setFill()
            NSBezierPath(roundedRect: r.insetBy(dx: 28, dy: 28), xRadius: 110, yRadius: 110).fill()
            let coral = NSColor(srgbRed: 1, green: 0.514, blue: 0.337, alpha: 1)
            coral.setFill()
            NSBezierPath(roundedRect: NSRect(x: 196, y: 120, width: 120, height: 34), xRadius: 10, yRadius: 10).fill()
            NSBezierPath(roundedRect: NSRect(x: 196, y: 358, width: 120, height: 34), xRadius: 10, yRadius: 10).fill()
            let body = NSBezierPath(roundedRect: NSRect(x: 170, y: 150, width: 172, height: 212), xRadius: 70, yRadius: 70)
            body.fill()
            NSColor(srgbRed: 0.969, green: 0.969, blue: 0.502, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 226, y: 220, width: 60, height: 80)).fill()
            coral.setStroke()
            let handle = NSBezierPath(); handle.lineWidth = 14
            handle.appendArc(withCenter: NSPoint(x: 256, y: 392), radius: 40, startAngle: 0, endAngle: 180)
            handle.stroke()
            return true
        }
    }
}
