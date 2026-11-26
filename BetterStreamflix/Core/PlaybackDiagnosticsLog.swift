import Foundation

/// In-app ring buffer for playback diagnostics. Everything the playback
/// pipeline already traces to stdout is mirrored here so users can copy the
/// log after a failed playback — no Xcode console needed.
enum PlaybackDiagnosticsLog {
    struct Entry: Identifiable, Sendable {
        let id = UUID()
        let timestamp: Date
        let message: String
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var storage: [Entry] = []
    private static let capacity = 400
    nonisolated(unsafe) private static var version = 0

    static func log(_ message: String) {
        lock.lock()
        storage.append(Entry(timestamp: Date(), message: message))
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
        version += 1
        lock.unlock()
    }

    static func entries() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    static func currentVersion() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return version
    }

    static func clear() {
        lock.lock()
        storage.removeAll()
        version += 1
        lock.unlock()
    }

    static func export() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withTime, .withFractionalSeconds]
        return entries().map { "\(formatter.string(from: $0.timestamp)) \($0.message)" }
            .joined(separator: "\n")
    }
}
