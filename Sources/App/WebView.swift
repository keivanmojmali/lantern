import AppKit
import WebKit
import UniformTypeIdentifiers

final class LWebView: WKWebView {
    var onDrop: (([String]) -> Void)?
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : super.draggingEntered(sender)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            onDrop?(urls.map { $0.path }); return true
        }
        return super.performDragOperation(sender)
    }
}

/// Serves local images referenced by plans: lantern-asset://f/<percent-encoded absolute path>
final class AssetScheme: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let path = String(url.path.dropFirst()).removingPercentEncoding ?? ""
        let full = "/" + path
        guard let data = FileManager.default.contents(atPath: full) else {
            task.didFailWithError(NSError(domain: "lantern", code: 404)); return
        }
        let mime = UTType(filenameExtension: (full as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
        task.didReceive(data); task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

final class LWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
