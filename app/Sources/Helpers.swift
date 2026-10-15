import Foundation

func sizeOfFiles(_ paths: [String]) -> UInt64 {
    paths.reduce(0) { acc, p in
        let v = (try? FileManager.default.attributesOfItem(atPath: p))?[.size] as? NSNumber
        return acc + UInt64(v?.int64Value ?? 0)
    }
}

extension SendContext {
    var pathsTotal: UInt64 { sizeOfFiles(paths) }
}

extension AppState {
    var pickerPathsTotal: UInt64 { sizeOfFiles(pickerPaths ?? []) }
}
