import Combine
import Foundation

struct MangaProgress: Codable, Hashable, Identifiable, Sendable {
    var manga: Manga
    var chapterID: String
    var chapterTitle: String?
    var pageIndex: Int
    var updatedAt: Date
    var readChapterIDs: Set<String>

    var id: String { MangaLibrary.key(manga) }
}

/// Manga favorites and reading progress per profile, ported from Android's
/// MangaFavoritesStore and MangaProgressStore (most recent 40 titles kept).
@MainActor
final class MangaLibrary: ObservableObject {
    static let shared = MangaLibrary()
    static let maxRecent = 40

    @Published private(set) var favorites: [Manga] = []
    @Published private(set) var progress: [MangaProgress] = []

    private let defaults: UserDefaults
    private var profileID: String
    private var profileObserver: AnyCancellable?

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        profileID = ProfileStore.shared.activeProfileID
        load()
        profileObserver = ProfileStore.shared.$activeProfileID
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] id in
                self?.profileID = id
                self?.load()
            }
    }

    nonisolated static func key(_ manga: Manga) -> String { "\(manga.providerID)|\(manga.id)" }

    func isFavorite(_ manga: Manga) -> Bool {
        favorites.contains { Self.key($0) == Self.key(manga) }
    }

    func toggleFavorite(_ manga: Manga) {
        if isFavorite(manga) {
            favorites.removeAll { Self.key($0) == Self.key(manga) }
        } else {
            favorites.insert(manga.summary, at: 0)
        }
        persist()
    }

    func progress(for manga: Manga) -> MangaProgress? {
        progress.first { $0.id == Self.key(manga) }
    }

    func isRead(_ chapter: MangaChapter, in manga: Manga) -> Bool {
        progress(for: manga)?.readChapterIDs.contains(chapter.id) ?? false
    }

    func save(manga: Manga, chapter: MangaChapter, pageIndex: Int, finished: Bool) {
        var entry = progress(for: manga) ?? MangaProgress(
            manga: manga.summary,
            chapterID: chapter.id,
            chapterTitle: chapter.displayTitle,
            pageIndex: pageIndex,
            updatedAt: Date(),
            readChapterIDs: []
        )
        if entry.chapterID == chapter.id, entry.pageIndex == pageIndex, !finished || entry.readChapterIDs.contains(chapter.id) {
            return
        }
        entry.manga = manga.summary
        entry.chapterID = chapter.id
        entry.chapterTitle = chapter.displayTitle
        entry.pageIndex = pageIndex
        entry.updatedAt = Date()
        if finished { entry.readChapterIDs.insert(chapter.id) }
        progress.removeAll { $0.id == entry.id }
        progress.insert(entry, at: 0)
        if progress.count > Self.maxRecent { progress.removeLast(progress.count - Self.maxRecent) }
        persist()
    }

    func setRead(_ chapter: MangaChapter, in manga: Manga, read: Bool) {
        guard var entry = progress(for: manga) else {
            if read { save(manga: manga, chapter: chapter, pageIndex: 0, finished: true) }
            return
        }
        if read { entry.readChapterIDs.insert(chapter.id) } else { entry.readChapterIDs.remove(chapter.id) }
        progress = progress.map { $0.id == entry.id ? entry : $0 }
        persist()
    }

    func removeProgress(_ entry: MangaProgress) {
        progress.removeAll { $0.id == entry.id }
        persist()
    }

    private var favoritesKey: String { "manga.favorites.v1.\(profileID)" }
    private var progressKey: String { "manga.progress.v1.\(profileID)" }

    private func load() {
        let decoder = JSONDecoder()
        favorites = defaults.data(forKey: favoritesKey).flatMap { try? decoder.decode([Manga].self, from: $0) } ?? []
        progress = defaults.data(forKey: progressKey).flatMap { try? decoder.decode([MangaProgress].self, from: $0) } ?? []
    }

    private func persist() {
        let encoder = JSONEncoder()
        defaults.set(try? encoder.encode(favorites), forKey: favoritesKey)
        defaults.set(try? encoder.encode(progress), forKey: progressKey)
    }
}
