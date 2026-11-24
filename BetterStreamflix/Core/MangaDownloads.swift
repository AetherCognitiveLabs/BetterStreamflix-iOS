import CryptoKit
import Foundation
import UIKit

struct MangaChapterDownload: Codable, Identifiable, Hashable, Sendable {
    enum State: String, Codable, Sendable { case queued, downloading, completed, failed }

    let id: String
    var manga: Manga
    let chapter: MangaChapter
    let folder: String
    var state: State = .queued
    var pagesDone = 0
    var pageCount = 0
    var bytesOnDisk: Int64 = 0
    var pageFiles: [String] = []
    var errorMessage: String?
    var createdAt = Date()
    /// Set after the background session was blocked (e.g. Cloudflare); the
    /// in-app loader can clear the check, the background session can't.
    var foregroundOnly: Bool?

    var progress: Double { pageCount > 0 ? Double(pagesDone) / Double(pageCount) : 0 }
}

/// Offline manga chapters: every page image is saved under
/// Application Support/MangaDownloads/<chapter>/ and the reader prefers it.
/// The page list is resolved in the app, then the images download through a
/// background URLSession so chapters keep going after the app is suspended.
@MainActor
final class MangaDownloadManager: NSObject, ObservableObject {
    static let shared = MangaDownloadManager()
    static let sessionID = "com.betterstreamflix.downloads.manga"
    private static let storageKey = "manga.downloads.v1"
    private static let concurrentPages = 4
    private static let concurrentChapters = 2

    @Published private(set) var items: [MangaChapterDownload] = []
    private var tasks: [String: Task<Void, Never>] = [:]
    private var session: URLSession!

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var directory = base.appendingPathComponent("MangaDownloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        return directory
    }

    private override init() {
        super.init()
        load()
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        configuration.httpMaximumConnectionsPerHost = Self.concurrentPages
        configuration.sessionSendsLaunchEvents = true
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        session.getAllTasks { [weak self] running in
            let ids = Set(running.compactMap { Self.parse($0.taskDescription)?.id })
            Task { @MainActor in self?.reattach(running: ids) }
        }
    }

    nonisolated static func id(_ manga: Manga, _ chapter: MangaChapter) -> String {
        MangaLibrary.key(manga) + "|" + chapter.id
    }

    var totalBytesOnDisk: Int64 { items.reduce(0) { $0 + $1.bytesOnDisk } }

    func item(_ manga: Manga, _ chapter: MangaChapter) -> MangaChapterDownload? {
        let id = Self.id(manga, chapter)
        return items.first { $0.id == id }
    }

    func completed(for manga: Manga) -> [MangaChapterDownload] {
        let key = MangaLibrary.key(manga)
        return items.filter { $0.state == .completed && MangaLibrary.key($0.manga) == key }
            .sorted { $0.chapter.number < $1.chapter.number }
    }

    /// Local pages for a finished download, or nil to load online.
    func localPages(for manga: Manga, chapter: MangaChapter) -> [MangaPage]? {
        guard let item = item(manga, chapter), item.state == .completed, !item.pageFiles.isEmpty else { return nil }
        let folder = Self.directory.appendingPathComponent(item.folder, isDirectory: true)
        let pages = item.pageFiles.enumerated().map { offset, file in
            MangaPage(index: offset, imageURL: folder.appendingPathComponent(file))
        }
        guard pages.allSatisfy({ FileManager.default.fileExists(atPath: $0.imageURL.path) }) else { return nil }
        return pages
    }

    func download(_ chapter: MangaChapter, of manga: Manga) {
        let id = Self.id(manga, chapter)
        if let existing = items.first(where: { $0.id == id }) {
            if existing.state == .failed { retry(id) }
            return
        }
        items.insert(newItem(chapter, of: manga), at: 0)
        persist()
        pump()
    }

    /// Queues every chapter not downloaded yet; chapters download two at a time
    /// in list order. Returns how many were added.
    @discardableResult
    func downloadAll(_ chapters: [MangaChapter], of manga: Manga) -> Int {
        let existing = Set(items.map(\.id))
        let fresh = chapters.filter { !existing.contains(Self.id(manga, $0)) }
        let base = Date()
        for (offset, chapter) in fresh.enumerated() {
            var item = newItem(chapter, of: manga)
            item.createdAt = base.addingTimeInterval(Double(offset) / 1000)
            items.insert(item, at: 0)
        }
        for item in items where item.state == .failed && chapters.contains(item.chapter) && MangaLibrary.key(item.manga) == MangaLibrary.key(manga) {
            update(item.id) {
                $0.state = .queued
                $0.errorMessage = nil
            }
        }
        persist()
        pump()
        return fresh.count
    }

    func removeAll(for manga: Manga) {
        let key = MangaLibrary.key(manga)
        for item in items where MangaLibrary.key(item.manga) == key { remove(item.id) }
    }

    func retry(_ id: String) {
        update(id) {
            $0.state = .queued
            $0.errorMessage = nil
            $0.pagesDone = 0
            $0.bytesOnDisk = 0
        }
        pump()
    }

    func cancel(_ id: String) { remove(id) }

    func remove(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        cancelSessionTasks(for: id)
        if let item = items.first(where: { $0.id == id }) {
            try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent(item.folder, isDirectory: true))
        }
        items.removeAll { $0.id == id }
        persist()
    }

    private func newItem(_ chapter: MangaChapter, of manga: Manga) -> MangaChapterDownload {
        let id = Self.id(manga, chapter)
        let digest = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        return MangaChapterDownload(id: id, manga: manga.summary, chapter: chapter, folder: String(digest.prefix(32)))
    }

    /// Starts the oldest queued chapters while fewer than two are resolving.
    private func pump() {
        while tasks.count < Self.concurrentChapters,
              let next = items.filter({ $0.state == .queued && tasks[$0.id] == nil }).min(by: { $0.createdAt < $1.createdAt }) {
            let id = next.id
            update(id) { $0.state = .downloading }
            tasks[id] = Task { [weak self] in
                await self?.run(id)
                self?.tasks[id] = nil
                self?.pump()
            }
        }
    }

    private func run(_ id: String) async {
        guard let item = items.first(where: { $0.id == id }) else { return }
        guard let provider = MangaCatalog.provider(id: item.manga.providerID) else {
            fail(id, "Unknown source \(item.manga.providerID)")
            return
        }
        let folder = Self.directory.appendingPathComponent(item.folder, isDirectory: true)
        do {
            let pages = try await provider.pages(chapterID: item.chapter.id)
            guard !pages.isEmpty else { throw AppError.providerUnavailable("No pages found") }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            update(id) {
                $0.pageCount = pages.count
                $0.pagesDone = 0
                $0.bytesOnDisk = 0
                $0.pageFiles = Array(repeating: "", count: pages.count)
            }
            if item.foregroundOnly == true {
                try await downloadInApp(id, pages: pages, folder: folder)
            } else {
                await enqueueInBackground(id, pages: pages)
            }
        } catch is CancellationError {
        } catch {
            fail(id, error.localizedDescription)
        }
    }

    private func enqueueInBackground(_ id: String, pages: [MangaPage]) async {
        for (offset, page) in pages.enumerated() {
            var request = URLRequest(url: page.imageURL, timeoutInterval: 60)
            var headers = page.headers
            if let clearance = await CloudflareResolver.shared.cachedClearance(for: page.imageURL) {
                headers.merge(clearance.headers) { _, cleared in cleared }
            }
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            let task = session.downloadTask(with: request)
            task.taskDescription = "\(offset)\t\(id)"
            task.resume()
        }
    }

    private func downloadInApp(_ id: String, pages: [MangaPage], folder: URL) async throws {
        var position = 0
        while position < pages.count {
            try Task.checkCancellation()
            let batch = Array(pages.enumerated())[position..<min(position + Self.concurrentPages, pages.count)]
            let saved = try await withThrowingTaskGroup(of: (Int, String, Int64).self) { group -> [(Int, String, Int64)] in
                for (offset, page) in batch {
                    group.addTask {
                        let (data, ext) = try await MangaImageCache.shared.data(for: page.imageURL, headers: page.headers)
                        let name = String(format: "%04d.%@", offset, ext)
                        try data.write(to: folder.appendingPathComponent(name), options: .atomic)
                        return (offset, name, Int64(data.count))
                    }
                }
                var result: [(Int, String, Int64)] = []
                for try await value in group { result.append(value) }
                return result
            }
            for (offset, name, size) in saved { pageFinished(id, index: offset, file: name, bytes: size) }
            position += batch.count
        }
    }

    // MARK: Background session bookkeeping

    nonisolated private static func parse(_ description: String?) -> (index: Int, id: String)? {
        guard let parts = description?.split(separator: "\t", maxSplits: 1), parts.count == 2,
              let index = Int(parts[0]) else { return nil }
        return (index, String(parts[1]))
    }

    private func pageFinished(_ id: String, index: Int, file: String, bytes: Int64) {
        update(id) {
            guard $0.pageFiles.indices.contains(index), $0.pageFiles[index].isEmpty else { return }
            $0.pageFiles[index] = file
            $0.pagesDone += 1
            $0.bytesOnDisk += bytes
            if $0.pagesDone >= $0.pageCount, $0.pageCount > 0 {
                $0.state = .completed
                $0.errorMessage = nil
            }
        }
    }

    private func pageFailed(_ id: String, message: String, blocked: Bool) {
        guard let item = items.first(where: { $0.id == id }), item.state == .downloading else { return }
        cancelSessionTasks(for: id)
        if blocked && item.foregroundOnly != true {
            update(id) {
                $0.foregroundOnly = true
                $0.state = .queued
            }
            pump()
        } else {
            fail(id, message)
        }
    }

    private func cancelSessionTasks(for id: String) {
        session?.getAllTasks { running in
            for task in running where Self.parse(task.taskDescription)?.id == id { task.cancel() }
        }
    }

    /// After a relaunch: chapters whose page tasks are still in the background
    /// session keep going, queued ones resume, the rest need a retry.
    private func reattach(running: Set<String>) {
        for item in items where item.state == .downloading && !running.contains(item.id) && tasks[item.id] == nil {
            if item.pageCount == 0 {
                update(item.id) { $0.state = .queued }
            } else {
                fail(item.id, "Interrupted")
            }
        }
        pump()
    }

    /// Queues WeebCentral's three newest One Piece chapters through
    /// `downloadAll`, checks every saved page decodes, then deletes them;
    /// used by `-mangaSmoke`.
    static func smokeDownload() async {
        let provider = WeebCentralMangaProvider()
        do {
            guard let first = try await provider.search("one piece").first else {
                print("MANGA DOWNLOAD FAIL no title")
                return
            }
            let manga = try await provider.manga(id: first.id)
            let chapters = Array(manga.chapters.suffix(3))
            let queued = shared.downloadAll(chapters, of: manga)
            let ids = chapters.map { Self.id(manga, $0) }
            for _ in 0..<150 {
                try await Task.sleep(for: .seconds(1))
                let pending = shared.items.filter { ids.contains($0.id) && ($0.state == .queued || $0.state == .downloading) }
                if pending.isEmpty { break }
            }
            for chapter in chapters {
                let id = Self.id(manga, chapter)
                let item = shared.items.first { $0.id == id }
                let local = shared.localPages(for: manga, chapter: chapter) ?? []
                let decodable = local.filter { (try? Data(contentsOf: $0.imageURL)).flatMap(UIImage.init(data:)) != nil }.count
                let ok = item?.state == .completed && !local.isEmpty && decodable == local.count
                print("MANGA DOWNLOAD \(ok ? "PASS" : "FAIL") queued=\(queued) path=\(item?.foregroundOnly == true ? "in-app" : "background") ch\(chapter.numberLabel) state=\(item?.state.rawValue ?? "nil") pages=\(item?.pageCount ?? 0) files=\(local.count) decodable=\(decodable) bytes=\(item?.bytesOnDisk ?? 0) \(item?.errorMessage ?? "")")
            }
            shared.removeAll(for: manga)
        } catch {
            print("MANGA DOWNLOAD FAIL \(error.localizedDescription)")
        }
    }

    private func fail(_ id: String, _ message: String) {
        update(id) {
            $0.state = .failed
            $0.errorMessage = message
        }
    }

    private func update(_ id: String, _ change: (inout MangaChapterDownload) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
        persist()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let saved = try? JSONDecoder().decode([MangaChapterDownload].self, from: data) else { return }
        items = saved
    }

    private func persist() {
        UserDefaults.standard.set(try? JSONEncoder().encode(items), forKey: Self.storageKey)
    }
}

extension MangaDownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let (index, id) = Self.parse(downloadTask.taskDescription) else { return }
        let response = downloadTask.response as? HTTPURLResponse
        let status = response?.statusCode ?? 0
        let mime = response?.mimeType?.lowercased() ?? ""
        guard (200...299).contains(status), mime.hasPrefix("image/") || mime.isEmpty || mime == "application/octet-stream" else {
            let blocked = status == 403 || status == 503 || mime.contains("html")
            MainActor.assumeIsolated { pageFailed(id, message: "Page \(index + 1): HTTP \(status)", blocked: blocked) }
            return
        }
        let ext = mime.contains("png") ? "png" : mime.contains("webp") ? "webp" : mime.contains("gif") ? "gif" : "jpg"
        let name = String(format: "%04d.%@", index, ext)
        // The temporary file is deleted when this returns, so move it now.
        MainActor.assumeIsolated {
            guard let item = items.first(where: { $0.id == id }) else { return }
            let target = Self.directory.appendingPathComponent(item.folder, isDirectory: true).appendingPathComponent(name)
            try? FileManager.default.removeItem(at: target)
            do {
                try FileManager.default.moveItem(at: location, to: target)
                let size = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                pageFinished(id, index: index, file: name, bytes: size)
            } catch {
                pageFailed(id, message: error.localizedDescription, blocked: false)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, (error as? URLError)?.code != .cancelled,
              let (index, id) = Self.parse(task.taskDescription) else { return }
        // Transport failures (no background daemon, unsigned builds) fall back
        // to downloading inside the app once.
        MainActor.assumeIsolated { pageFailed(id, message: "Page \(index + 1): \(error.localizedDescription)", blocked: true) }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let identifier = session.configuration.identifier
        MainActor.assumeIsolated { BackgroundSessionEvents.finish(identifier) }
    }
}
