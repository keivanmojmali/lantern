import AppKit
import ApplicationServices

/// Keeps a borderless window glued over part of the front Ghostty window.
/// Finds Ghostty's window with CGWindowList (no permission needed). If Accessibility is granted,
/// it also tries to find a real split rectangle; otherwise it covers the configured % of the window.
final class PaneOverlay {
    weak var window: NSWindow?
    var widthPct: () -> Double
    var side: () -> String
    private var timer: Timer?
    private(set) var ghosttyFound = false
    var lastGhosttyBounds: CGRect = .zero
    var titlebarInset: CGFloat = 28
    var usedAX = false

    init(window: NSWindow, widthPct: @escaping () -> Double, side: @escaping () -> String) {
        self.window = window; self.widthPct = widthPct; self.side = side
    }
    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }
    func stop() { timer?.invalidate(); timer = nil }

    /// Front-most on-screen Ghostty window: (CG bounds with top-left origin, window number, index in z-order).
    func ghosttyWindow() -> (CGRect, Int, Int, [Int])? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let ids = list.compactMap { $0[kCGWindowNumber as String] as? Int }
        for (i, w) in list.enumerated() {
            guard (w[kCGWindowOwnerName as String] as? String) == "Ghostty",
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let n = w[kCGWindowNumber as String] as? Int else { continue }
            let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            if r.width > 200 && r.height > 120 { return (r, n, i, ids) }
        }
        return nil
    }

    func tick() {
        guard let win = window else { return }
        guard let (g, num, gi, ids) = ghosttyWindow() else {
            ghosttyFound = false
            if win.isVisible { win.orderOut(nil) }
            return
        }
        ghosttyFound = true
        lastGhosttyBounds = g
        let cg = targetRect(in: g)
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let r = NSRect(x: cg.minX, y: primaryH - cg.maxY, width: cg.width, height: cg.height)
        if win.frame != r { win.setFrame(r, display: true) }
        // keep directly above Ghostty, but below other apps' windows
        let mine = ids.firstIndex(of: win.windowNumber)
        if !win.isVisible || mine == nil || mine! > gi { win.order(.above, relativeTo: num) }
    }

    private func targetRect(in g: CGRect) -> CGRect {
        if let r = splitRectViaAX(ghostty: g) { usedAX = true; return r }
        usedAX = false
        let pct = max(0.1, min(0.9, widthPct() / 100))
        let w = (g.width * pct).rounded()
        let y = g.minY + titlebarInset
        let h = g.height - titlebarInset
        return CGRect(x: side() == "left" ? g.minX : g.maxX - w, y: y, width: w, height: h)
    }

    // MARK: Accessibility spike — look for a real AXSplitGroup and cover its last/first child.
    private var axCache: (Date, CGRect?)?
    private func splitRectViaAX(ghostty g: CGRect) -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        if let c = axCache, Date().timeIntervalSince(c.0) < 0.5 { return c.1 }
        var found: CGRect?
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.mitchellh.ghostty").first {
            let el = AXUIElementCreateApplication(app.processIdentifier)
            var win: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXFocusedWindowAttribute as CFString, &win) == .success {
                found = findSplit(win as! AXUIElement, depth: 0, window: g)
            }
        }
        axCache = (Date(), found)
        return found
    }
    private func frame(_ e: AXUIElement) -> CGRect? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, "AXFrame" as CFString, &v) == .success, let val = v else { return nil }
        var r = CGRect.zero
        return AXValueGetValue(val as! AXValue, .cgRect, &r) ? r : nil
    }
    private func findSplit(_ e: AXUIElement, depth: Int, window g: CGRect) -> CGRect? {
        if depth > 8 { return nil }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &role)
        var kids: CFTypeRef?
        AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &kids)
        let children = (kids as? [AXUIElement]) ?? []
        if (role as? String) == "AXSplitGroup" {
            let frames = children.compactMap { frame($0) }.filter { $0.width > 80 && $0.height > 80 }
            if frames.count >= 2 { return side() == "left" ? frames.min { $0.minX < $1.minX } : frames.max { $0.minX < $1.minX } }
        }
        for c in children { if let r = findSplit(c, depth: depth + 1, window: g) { return r } }
        return nil
    }
}
