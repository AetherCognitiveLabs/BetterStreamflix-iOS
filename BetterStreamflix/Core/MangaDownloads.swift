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

    var progress: Double { pageCount > 0 ? Double(pagesDone) / Double(pageCount) : 0 }
}

/// Offline manga chapters: every page image is saved under
/// Application Support/MangaDownloads/<chapter>/ and the reader prefers it.
@MainActor
final class MangaDownloadManager: ObservableObject {
    static let shared = MangaDownloadManager()
    private static let storageKey = "manga.downloads.v1"
    private static let concurrentPages = 4
    private static let concurrentChapters = 2

    @Published private(set) var items: [MangaChapterDownload] = []
    private var tasks: [String: Task<Void, Never>] = [:]

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var directory = base.appendingPathComponent("MangaDownloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        return directory
    }

    private init() {
        load()
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

    private func newItem(_ chapter: MangaChapter, of manga: Manga) -> MangaChapterDownload {
        let id = Self.id(manga, chapter)
        let digest = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        return MangaChapterDownload(id: id, manga: manga.summary, chapter: chapter, folder: String(digest.prefix(32)))
    }

    func retry(_ id: String) {
        update(id) {
            $0.state = .queued
            $0.errorMessage = nil
            $0.pagesDone = 0
        }
        pump()
    }

    func cancel(_ id: String) { remove(id) }

    func remove(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        if let item = items.first(where: { $0.id == id }) {
            try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent(item.folder, isDirectory: true))
        }
        items.removeAll { $0.id == id }
        persist()
    }

    /// Starts the oldest queued chapters while fewer than two are running.
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
        update(id) { $0.state = .downloading }
        let folder = Self.directory.appendingPathComponent(item.folder, isDirectory: true)
        do {
            let pages = try await provider.pages(chapterID: item.chapter.id)
            guard !pages.isEmpty else { throw AppError.providerUnavailable("No pages found") }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            update(id) { $0.pageCount = pages.count }
            var files = Array(repeating: "", count: pages.count)
            var bytes: Int64 = 0
            var position = 0
            while position < pages.count {
                try Task.checkCancellation()
                let batch = Array(pages.enumerated())[position..<min(position + Self.concurrentPages, pages.count)]
                try await withThrowingTaskGroup(of: (Int, String, Int64).self) { group in
                    for (offset, page) in batch {
                        group.addTask {
                            let (data, ext) = try await MangaImageCache.shared.data(for: page.imageURL, headers: page.headers)
                            let name = String(format: "%04d.%@", offset, ext)
                            try data.write(to: folder.appendingPathComponent(name), options: .atomic)
                            return (offset, name, Int64(data.count))
                        }
                    }
                    for try await (offset, name, size) in group {
                        files[offset] = name
                        bytes += size
                    }
                }
                position += batch.count
                let done = position, total = bytes
                update(id) {
                    $0.pagesDone = done
                    $0.bytesOnDisk = total
                }
            }
            update(id) {
                $0.state = .completed
                $0.pageFiles = files
            }
        } catch is CancellationError {
        } catch {
            fail(id, error.localizedDescription)
        }
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
                print("MANGA DOWNLOAD \(ok ? "PASS" : "FAIL") queued=\(queued) ch\(chapter.numberLabel) state=\(item?.state.rawValue ?? "nil") pages=\(item?.pageCount ?? 0) files=\(local.count) decodable=\(decodable) bytes=\(item?.bytesOnDisk ?? 0) \(item?.errorMessage ?? "")")
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
        items = saved.map { item in
            var item = item
            if item.state == .queued || item.state == .downloading {
                item.state = .failed
                item.errorMessage = "Interrupted"
            }
            return item
        }
    }

    private func persist() {
        UserDefaults.standard.set(try? JSONEncoder().encode(items), forKey: Self.storageKey)
    }
}
