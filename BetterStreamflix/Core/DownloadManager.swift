import AVFoundation
import Foundation

/// An offline copy of one title/episode. HLS streams are saved as `.movpkg`
/// through AVAssetDownloadURLSession; progressive files (mp4/mkv/…) are
/// fetched with a URLSession download task into Application Support/Downloads.
struct DownloadItem: Codable, Identifiable, Hashable, Sendable {
    enum State: String, Codable, Sendable {
        case queued, downloading, completed, failed
    }

    let id: String
    let request: PlaybackRequest
    let providerName: String
    let audioLanguage: String
    let sourceURL: URL
    let headers: [String: String]
    let isHLS: Bool
    var state: State = .queued
    var progress: Double = 0
    var bytesOnDisk: Int64 = 0
    var expectedBytes: Int64 = 0
    var relativePath: String?
    var errorMessage: String?
    var createdAt = Date()
    var completedAt: Date?

    var title: String { request.nowPlayingTitle }
    var subtitle: String? { request.nowPlayingSubtitle }
}

@MainActor
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var items: [DownloadItem] = []

    private static let storeKey = "downloads.items.v1"
    private static let hlsSessionID = "com.betterstreamflix.downloads.hls"
    private var hlsSession: AVAssetDownloadURLSession!
    private var fileSession: URLSession!
    private var tasks: [String: URLSessionTask] = [:]

    static var filesDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = directory
        try? mutable.setResourceValues(values)
        return directory
    }

    private override init() {
        super.init()
        load()
        hlsSession = AVAssetDownloadURLSession(
            configuration: .background(withIdentifier: Self.hlsSessionID),
            assetDownloadDelegate: self,
            delegateQueue: .main
        )
        fileSession = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        hlsSession.getAllTasks { [weak self] running in
            Task { @MainActor in self?.reattach(running) }
        }
    }

    // MARK: Queries

    func item(for contentID: String) -> DownloadItem? { items.first { $0.id == contentID } }

    func localURL(for contentID: String) -> URL? {
        guard let item = item(for: contentID), item.state == .completed, let url = Self.localURL(for: item),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    static func localURL(for item: DownloadItem) -> URL? {
        guard let path = item.relativePath else { return nil }
        return item.isHLS
            ? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(path)
            : filesDirectory.appendingPathComponent(path)
    }

    var totalBytesOnDisk: Int64 { items.reduce(0) { $0 + $1.bytesOnDisk } }

    // MARK: Actions

    /// Queues the source currently playing for `request`. Returns false for
    /// sources that can't be saved (already downloaded or non-HTTP).
    @discardableResult
    func start(request: PlaybackRequest, source: PlaybackSource, candidate: PlaybackCandidate?) -> Bool {
        guard source.url.scheme?.hasPrefix("http") == true else { return false }
        if let existing = item(for: request.contentID), existing.state != .failed { return false }
        remove(request.contentID)
        let lower = source.url.absoluteString.lowercased()
        let item = DownloadItem(
            id: request.contentID,
            request: request,
            providerName: candidate?.providerName ?? "Stream",
            audioLanguage: candidate?.preference.audioLanguage ?? "",
            sourceURL: source.url,
            headers: source.headers,
            isHLS: lower.contains(".m3u8") || lower.contains("/hls/") || lower.contains("format=m3u8")
        )
        items.insert(item, at: 0)
        begin(item)
        return true
    }

    func retry(_ id: String) {
        guard var item = item(for: id) else { return }
        item.state = .queued
        item.progress = 0
        item.errorMessage = nil
        update(item)
        begin(item)
    }

    func cancel(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        remove(id)
    }

    func remove(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        if let item = item(for: id), let url = Self.localURL(for: item) {
            try? FileManager.default.removeItem(at: url)
        }
        items.removeAll { $0.id == id }
        save()
    }

    private func begin(_ item: DownloadItem) {
        let task: URLSessionTask
        if item.isHLS {
            let options: [String: Any]? = item.headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": item.headers]
            let asset = AVURLAsset(url: item.sourceURL, options: options)
            guard let assetTask = hlsSession.makeAssetDownloadTask(
                asset: asset,
                assetTitle: item.title,
                assetArtworkData: nil,
                options: [AVAssetDownloadTaskMinimumRequiredMediaBitrateKey: 2_000_000]
            ) else {
                fail(item.id, message: "This stream can't be downloaded.")
                return
            }
            task = assetTask
        } else {
            var request = URLRequest(url: item.sourceURL)
            item.headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
            task = fileSession.downloadTask(with: request)
        }
        task.taskDescription = item.id
        tasks[item.id] = task
        var running = item
        running.state = .downloading
        update(running)
        task.resume()
    }

    private func reattach(_ running: [URLSessionTask]) {
        for task in running {
            guard let id = task.taskDescription, item(for: id) != nil else { task.cancel(); continue }
            tasks[id] = task
        }
        for item in items where (item.state == .downloading || item.state == .queued) && tasks[item.id] == nil {
            fail(item.id, message: "Interrupted. Tap retry to continue.")
        }
    }

    // MARK: State

    private func update(_ item: DownloadItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item
        save()
    }

    private func mutate(_ id: String, _ change: (inout DownloadItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    private func fail(_ id: String, message: String) {
        mutate(id) {
            $0.state = .failed
            $0.errorMessage = message
        }
        tasks[id] = nil
        save()
    }

    private func finish(_ id: String, relativePath: String) {
        mutate(id) { item in
            item.relativePath = relativePath
            item.state = .completed
            item.progress = 1
            item.completedAt = Date()
            if let url = Self.localURL(for: item) { item.bytesOnDisk = Self.size(of: url) }
        }
        tasks[id] = nil
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storeKey),
              let decoded = try? JSONDecoder().decode([DownloadItem].self, from: data) else { return }
        items = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }

    nonisolated static func size(of url: URL) -> Int64 {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else {
            return Int64((try? manager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0)
        }
        var total: Int64 = 0
        let enumerator = manager.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        while let file = enumerator?.nextObject() as? URL {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }
}

extension DownloadManager: AVAssetDownloadDelegate, URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let id = assetDownloadTask.taskDescription else { return }
        let path = location.relativePath
        MainActor.assumeIsolated {
            mutate(id) { $0.relativePath = path }
            save()
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        didLoad timeRange: CMTimeRange,
        totalTimeRangesLoaded loadedTimeRanges: [NSValue],
        timeRangeExpectedToLoad: CMTimeRange
    ) {
        guard let id = assetDownloadTask.taskDescription else { return }
        let expected = timeRangeExpectedToLoad.duration.seconds
        guard expected > 0 else { return }
        let loaded = loadedTimeRanges.reduce(0.0) { $0 + $1.timeRangeValue.duration.seconds }
        MainActor.assumeIsolated {
            mutate(id) { $0.progress = min(loaded / expected, 1) }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let id = downloadTask.taskDescription else { return }
        MainActor.assumeIsolated {
            mutate(id) { item in
                item.bytesOnDisk = totalBytesWritten
                if totalBytesExpectedToWrite > 0 {
                    item.expectedBytes = totalBytesExpectedToWrite
                    item.progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
                }
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let id = downloadTask.taskDescription else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            MainActor.assumeIsolated { fail(id, message: "Server answered HTTP \(http.statusCode).") }
            return
        }
        let mime = downloadTask.response?.mimeType ?? ""
        var ext = downloadTask.originalRequest?.url?.pathExtension ?? ""
        if ext.isEmpty || ext.count > 4 { ext = mime.contains("matroska") ? "mkv" : "mp4" }
        let name = id.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression) + "." + ext
        let destination = DownloadManager.filesDirectoryNonisolated.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            MainActor.assumeIsolated { finish(id, relativePath: name) }
        } catch {
            MainActor.assumeIsolated { fail(id, message: error.localizedDescription) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription else { return }
        let isAsset = task is AVAssetDownloadTask
        MainActor.assumeIsolated {
            if let error {
                if (error as? URLError)?.code == .cancelled, item(for: id) == nil { return }
                fail(id, message: error.localizedDescription)
            } else if isAsset, let path = item(for: id)?.relativePath {
                finish(id, relativePath: path)
            }
        }
    }

    nonisolated static var filesDirectoryNonisolated: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

/// Plays finished downloads through the normal player: offered first in
/// discovery for the matching title/episode.
struct OfflinePlaybackProvider: PlaybackProvider {
    var id: String { "offline" }

    func candidates(for context: PlaybackLookupContext) async throws -> [PlaybackCandidate] {
        let contentID = context.request.contentID
        guard let (url, item) = await MainActor.run(body: { () -> (URL, DownloadItem)? in
            guard let url = DownloadManager.shared.localURL(for: contentID),
                  let item = DownloadManager.shared.item(for: contentID) else { return nil }
            return (url, item)
        }) else { return [] }
        return [PlaybackCandidate(
            id: "offline:\(contentID)",
            preference: PlaybackSourcePreference(providerID: id, serverName: "Downloaded", audioLanguage: item.audioLanguage),
            providerName: "Downloaded · \(item.providerName)",
            subtitleKind: .unknown
        ) {
            PlaybackSource(url: url, headers: [:], subtitles: [], preferredPeakBitRate: nil)
        }]
    }
}
