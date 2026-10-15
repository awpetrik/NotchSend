import Foundation

/// NDJSON client for the notchsendd control socket (POSIX, no dependencies).
/// Contract extracted from crates/daemon/src/main.rs + tools/notchsendctl:
///   -> {"type":"hello","client":"NotchSend","ipc_version":1}
///   <- {"type":"welcome", ipc_version, daemon_version, alias, fingerprint, port}
///   <- {"type":"snapshot", seq, peers[], pending, session}
///   <- {"type":"event","event":<name>,"seq":N, ...payload}
///   <- {"type":"result","id":..., "ok":bool, ...}
/// Commands: accept{request_id,file_ids?}, reject{request_id},
///           send{address,fingerprint?,pin?,paths[]}, cancel{session_id},
///           rescan, status, peers. set_config/shutdown are NOT supported
///           by the spike daemon (result ok=false, error "unsupported").
final class DaemonClient {
    let socketPath: String
    var onMessage: ((JObj) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?

    private var fd: Int32 = -1
    private let writeLock = NSLock()
    private var counter = 0
    private var running = false
    private var connectedNow = false

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func start() {
        guard !running else { return }
        running = true
        Thread.detachNewThread { [weak self] in self?.loop() }
    }

    private func loop() {
        var backoff: TimeInterval = 0.5
        while running {
            if connectAndRead() {
                backoff = 0.5
            }
            if connectedNow {
                connectedNow = false
                onConnectionChange?(false)
            }
            Thread.sleep(forTimeInterval: backoff)
            backoff = min(backoff * 2, 5)
        }
    }

    /// Returns true if a connection was established (even if it later dropped).
    private func connectAndRead() -> Bool {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        if s < 0 { return false }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
                let n = min(pathBytes.count, 103)
                for i in 0..<n { dst[i] = CChar(bitPattern: pathBytes[i]) }
                dst[n] = 0
            }
        }
        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(s, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if ok != 0 {
            close(s)
            return false
        }
        fd = s
        connectedNow = true
        onConnectionChange?(true)
        sendJSON(["type": "hello", "client": "NotchSend", "ipc_version": 1])

        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while running {
            let n = read(s, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = Data(buffer[0..<nl])
                buffer.removeSubrange(0...nl)
                if lineData.isEmpty { continue }
                if let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? JObj {
                    onMessage?(obj)
                }
            }
        }
        close(s)
        if fd == s { fd = -1 }
        return true
    }

    func sendJSON(_ obj: JObj) {
        guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(0x0A)
        writeLock.lock()
        defer { writeLock.unlock() }
        let f = fd
        if f < 0 { return }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let w = write(f, base.advanced(by: sent), raw.count - sent)
                if w <= 0 { break }
                sent += w
            }
        }
    }

    @discardableResult
    func command(_ obj: JObj) -> String {
        counter += 1
        let id = "app-\(counter)"
        var o = obj
        o["id"] = id
        sendJSON(o)
        return id
    }
}
