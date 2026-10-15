import Foundation

// MARK: - Logging

enum Log {
    static let dir: URL = {
        let d = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/NotchSend")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    static let file: URL = dir.appendingPathComponent("geometry.log")

    static func line(_ s: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let text = "[\(ts)] \(s)\n"
        if let data = text.data(using: .utf8) {
            if let h = try? FileHandle(forWritingTo: file) {
                h.seekToEndOfFile()
                h.write(data)
                try? h.close()
            } else {
                try? data.write(to: file)
            }
        }
        FileHandle.standardError.write(text.data(using: .utf8)!)
    }
}

// MARK: - JSON helpers (daemon speaks heterogeneous JSON; JSONSerialization wins)

typealias JObj = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func str(_ k: String) -> String? { self[k] as? String }
    func int(_ k: String) -> Int? {
        if let n = self[k] as? NSNumber { return n.intValue }
        return nil
    }
    func u64(_ k: String) -> UInt64 {
        if let n = self[k] as? NSNumber { return n.uint64Value }
        return 0
    }
    func obj(_ k: String) -> JObj? { self[k] as? JObj }
    func arr(_ k: String) -> [Any]? { self[k] as? [Any] }
    func bool(_ k: String) -> Bool { (self[k] as? Bool) ?? false }
}

// MARK: - Domain models

struct Peer: Identifiable {
    var id: String { fingerprint }
    let fingerprint: String
    var alias: String
    var deviceModel: String?
    var deviceType: String?
    var ip: String
    var port: Int
    var proto: String
    var lastSeen: UInt64 // epoch seconds

    var isOnline: Bool {
        let now = UInt64(Date().timeIntervalSince1970)
        return now >= lastSeen && now - lastSeen < 150
    }
    var address: String { "\(ip):\(port)" }
    var symbol: String {
        switch (deviceType ?? "").lowercased() {
        case "mobile": return "iphone"
        case "desktop": return "desktopcomputer"
        case "web": return "globe"
        case "server": return "server.rack"
        default: return deviceModel != nil ? "iphone" : "desktopcomputer"
        }
    }
    var metaLine: String {
        var parts: [String] = []
        if let m = deviceModel, !m.isEmpty { parts.append(m) }
        else if let t = deviceType, !t.isEmpty { parts.append(t.capitalized) }
        parts.append(ip)
        return parts.joined(separator: ", ")
    }

    static func parse(_ j: JObj) -> Peer? {
        guard let fp = j.str("fingerprint") else { return nil }
        return Peer(
            fingerprint: fp,
            alias: j.str("alias") ?? "Perangkat",
            deviceModel: j.str("device_model"),
            deviceType: j.str("device_type"),
            ip: j.str("ip") ?? "",
            port: j.int("port") ?? 53317,
            proto: j.str("protocol") ?? "https",
            lastSeen: j.u64("last_seen")
        )
    }
}

struct TransferFile: Identifiable {
    let id: String
    var name: String
    var size: UInt64
    var fileType: String?
    var bytesDone: UInt64 = 0
    var status: String = "queued" // queued | transferring | verifying | done | failed
    var savedPath: String? = nil

    var fraction: Double {
        size == 0 ? (status == "done" ? 1 : 0) : min(1, Double(bytesDone) / Double(size))
    }

    static func parse(_ j: JObj) -> TransferFile? {
        guard let id = j.str("id"), let name = j.str("name") else { return nil }
        var f = TransferFile(id: id, name: name, size: j.u64("size"),
                             fileType: j.str("file_type"))
        f.bytesDone = j.u64("bytes_done")
        if let s = j.str("status") { f.status = s }
        f.savedPath = j.str("saved_path")
        if f.status == "done" { f.bytesDone = f.size }
        return f
    }
}

struct PendingRequest {
    let requestId: String
    var senderAlias: String
    var senderType: String?
    var senderIP: String
    var files: [TransferFile]
    var totalSize: UInt64
    var receivedAt: Date
}

struct SessionState {
    var id: String
    var direction: String // "receive" | "send"
    var peerAlias: String
    var peerAddress: String?
    var files: [TransferFile]
    var totalSize: UInt64
    var aggregateDone: UInt64 = 0
    var rate: Double = 0 // bytes/sec, computed locally (daemon sends no rate)
    var startedAt = Date()
    var lastSampleTime = Date()
    var lastSampleDone: UInt64 = 0

    var fraction: Double {
        totalSize == 0 ? 0 : min(1, Double(aggregateDone) / Double(totalSize))
    }
    var currentFile: TransferFile? {
        files.first(where: { $0.status == "transferring" || $0.status == "verifying" })
            ?? files.first(where: { $0.status == "queued" })
            ?? files.last
    }
}

/// Summary of the most recent finished transfer, rendered on the home
/// page (M15) as a two-line row with an optional Finder action. Replaces
/// the old flat summary string, which carried no file name, no size and
/// no action.
struct LastTransfer {
    enum Outcome { case completed, failed, cancelled }
    var direction: String // "receive" | "send"
    var peerAlias: String
    var fileNames: [String]
    var totalSize: UInt64
    var savedPaths: [String]
    var finishedAt: Date
    var outcome: Outcome
    /// Failure title for the failed outcome, shown when no file names
    /// were captured (e.g. a receive that failed before session start).
    var title: String = ""
}

// MARK: - Formatting

func fmtBytes(_ b: UInt64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var v = Double(b)
    var i = 0
    while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
    if i == 0 { return "\(b) B" }
    let s = String(format: v >= 100 ? "%.0f" : "%.1f", v).replacingOccurrences(of: ".", with: ",")
    return "\(s) \(units[i])"
}

func fmtRate(_ r: Double) -> String {
    if r <= 0 { return "" }
    return fmtBytes(UInt64(r)) + "/dtk"
}

func fmtETA(_ seconds: Double) -> String {
    if seconds <= 0 || seconds.isInfinite || seconds.isNaN { return "" }
    if seconds < 60 { return "sisa ~\(Int(seconds.rounded())) dtk" }
    return "sisa ~\(Int((seconds / 60).rounded())) mnt"
}

func fmtClock(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH.mm"
    return f.string(from: d)
}

func fmtCountdown(_ secs: Int) -> String {
    let s = max(0, secs)
    return String(format: "%02d:%02d", s / 60, s % 60)
}
