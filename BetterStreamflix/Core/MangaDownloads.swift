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
        let digest = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        items.insert(MangaChapterDownload(id: id, manga: manga.summary, chapter: chapter, folder: String(digest.prefix(32))), at: 0)
        persist()
        start(id)
    }

    func retry(_ id: String) {
        update(id) {
            $0.state = .queued
            $0.errorMessage = nil
            $0.pagesDone = 0
        }
        start(id)
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

    private func start(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = Task { [weak self] in
            await self?.run(id)
            self?.tasks[id] = nil
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

    /// Downloads one WeebCentral chapter, checks the files and deletes it again;
    /// used by `-mangaSmoke`.
    static func smokeDownload() async {
        let provider = WeebCentralMangaProvider()
        do {
            guard let first = try await provider.search("one piece").first,
                  let chapter = try await provider.manga(id: first.id).chapters.last else {
                print("MANGA DOWNLOAD FAIL no chapter")
                return
            }
            let manga = try await provider.manga(id: first.id)
            shared.download(chapter, of: manga)
            let id = Self.id(manga, chapter)
            for _ in 0..<90 {
                try await Task.sleep(for: .seconds(1))
                guard let item = shared.items.first(where: { $0.id == id }), item.state == .queued || item.state == .downloading else { break }
            }
            let item = shared.items.first { $0.id == id }
            let local = shared.localPages(for: manga, chapter: chapter) ?? []
            let decodable = local.filter { (try? Data(contentsOf: $0.imageURL)).flatMap(UIImage.init(data:)) != nil }.count
            print("MANGA DOWNLOAD \(item?.state == .completed && decodable == local.count && !local.isEmpty ? "PASS" : "FAIL") state=\(item?.state.rawValue ?? "nil") pages=\(item?.pageCount ?? 0) files=\(local.count) decodable=\(decodable) bytes=\(item?.bytesOnDisk ?? 0) \(item?.errorMessage ?? "")")
            shared.remove(id)
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
