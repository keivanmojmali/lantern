import Foundation
import Darwin

/// Line-delimited JSON over a Unix socket. Handler runs on main; reply may be async.
final class IPCServer {
    typealias Reply = ([String: Any]) -> Void
    private var fd: Int32 = -1
    private let handler: ([String: Any], @escaping Reply) -> Void
    init(handler: @escaping ([String: Any], @escaping Reply) -> Void) { self.handler = handler }

    func start() {
        let path = LPaths.socket
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < 104 else { NSLog("lantern: socket path too long"); return }
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: 104) { _ = strlcpy($0, path, 104) }
        }
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard ok == 0, listen(fd, 8) == 0 else { NSLog("lantern: cannot bind \(path)"); return }
        chmod(path, 0o600)
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
    }
    func stop() { if fd >= 0 { close(fd) }; unlink(LPaths.socket) }

    private func acceptLoop() {
        while true {
            let c = accept(fd, nil, nil)
            if c < 0 { return }
            Thread.detachNewThread { [weak self] in self?.serve(c) }
        }
    }
    private func serve(_ c: Int32) {
        var buf = Data(); var chunk = [UInt8](repeating: 0, count: 65536)
        while !buf.contains(10) {
            let n = read(c, &chunk, chunk.count)
            if n <= 0 { close(c); return }
            buf.append(chunk, count: n)
        }
        let obj = (try? JSONSerialization.jsonObject(with: buf)) as? [String: Any] ?? [:]
        let sem = DispatchSemaphore(value: 0)
        var result: [String: Any] = ["error": "no reply"]
        DispatchQueue.main.async { [handler] in
            handler(obj) { r in result = r; sem.signal() }
        }
        _ = sem.wait(timeout: .now() + 30)
        var out = (try? JSONSerialization.data(withJSONObject: result)) ?? Data("{}".utf8)
        out.append(10)
        _ = out.withUnsafeBytes { write(c, $0.baseAddress, out.count) }
        close(c)
    }
}
