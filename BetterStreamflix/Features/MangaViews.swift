import SwiftUI
import UIKit

enum MangaRoute: Hashable {
    case detail(Manga)
}

// MARK: Browser

struct MangaHomeView: View {
    @ObservedObject private var library = MangaLibrary.shared
    @AppStorage("manga.providerID") private var providerID = MangaCatalog.all[0].id
    @State private var query = ""
    @State private var categories: [MangaCategory] = []
    @State private var results: [Manga] = []
    @State private var isLoading = false
    @State private var errorText: String?

    private var provider: any MangaProvider { MangaCatalog.provider(id: providerID) ?? MangaCatalog.all[0] }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        List {
            if trimmedQuery.isEmpty {
                if !library.progress.isEmpty {
                    Section("Continue Reading") {
                        MangaCoverRow(items: library.progress.map(\.manga)) { manga in
                            library.progress(for: manga)?.chapterTitle
                        }
                    }
                }
                if !library.favorites.isEmpty {
                    Section("Favorites") { MangaCoverRow(items: library.favorites) }
                }
                ForEach(categories) { category in
                    Section("\(category.name) · \(provider.name)") { MangaCoverRow(items: category.items) }
                }
            } else {
                Section("Results · \(provider.name)") {
                    ForEach(results) { manga in
                        NavigationLink(value: MangaRoute.detail(manga)) { MangaListRow(manga: manga) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Manga")
        .searchable(text: $query, prompt: "Search \(provider.name)")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Source", selection: $providerID) {
                        ForEach(MangaCatalog.all, id: \.id) { Text($0.name).tag($0.id) }
                    }
                } label: {
                    Label(provider.name, systemImage: "books.vertical")
                }
            }
        }
        .overlay {
            if isLoading && categories.isEmpty && results.isEmpty {
                ProgressView()
            } else if let errorText, categories.isEmpty, results.isEmpty {
                ContentUnavailableView("Couldn't load \(provider.name)", systemImage: "exclamationmark.triangle", description: Text(errorText))
            } else if !trimmedQuery.isEmpty, results.isEmpty, !isLoading {
                ContentUnavailableView.search(text: trimmedQuery)
            }
        }
        .task(id: providerID) { await loadHome() }
        .task(id: "\(providerID)|\(trimmedQuery)") { await search() }
        .refreshable { await loadHome() }
        .navigationDestination(for: MangaRoute.self) { route in
            switch route {
            case .detail(let manga): MangaDetailView(manga: manga)
            }
        }
    }

    private func loadHome() async {
        let provider = provider
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do {
            let loaded = try await provider.home()
            guard provider.id == providerID else { return }
            categories = loaded
            await ProviderHealth.shared.recordSuccess(provider.id)
        } catch is CancellationError {
        } catch {
            categories = []
            errorText = error.localizedDescription
            await ProviderHealth.shared.recordFailure(provider.id)
        }
    }

    private func search() async {
        let term = trimmedQuery
        guard !term.isEmpty else {
            results = []
            return
        }
        try? await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let found = try await provider.search(term)
            guard !Task.isCancelled else { return }
            results = found
            errorText = nil
        } catch is CancellationError {
        } catch {
            results = []
            errorText = error.localizedDescription
        }
    }
}

private struct MangaCoverRow: View {
    let items: [Manga]
    var caption: (Manga) -> String? = { _ in nil }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(items, id: \.self) { manga in
                    NavigationLink(value: MangaRoute.detail(manga)) {
                        VStack(alignment: .leading, spacing: 4) {
                            MangaCover(manga: manga)
                                .frame(width: 104, height: 152)
                            Text(manga.title)
                                .font(.caption.weight(.semibold))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            if let caption = caption(manga) {
                                Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .frame(width: 104, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .listRowInsets(EdgeInsets())
    }
}

private struct MangaListRow: View {
    let manga: Manga

    var body: some View {
        HStack(spacing: 12) {
            MangaCover(manga: manga).frame(width: 54, height: 78)
            VStack(alignment: .leading, spacing: 3) {
                Text(manga.title).font(.body.weight(.semibold)).lineLimit(2)
                if let status = manga.status { Text(status).font(.caption).foregroundStyle(.secondary) }
                if let overview = manga.overview {
                    Text(overview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
    }
}

private struct MangaCover: View {
    let manga: Manga

    var body: some View {
        MangaRemoteImage(
            url: manga.cover,
            headers: MangaCatalog.provider(id: manga.providerID)?.imageHeaders ?? [:],
            contentMode: .fill
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: Chapters

struct MangaDetailView: View {
    let manga: Manga
    @ObservedObject private var library = MangaLibrary.shared
    @AppStorage("manga.chapters.newestFirst") private var newestFirst = true
    @State private var detail: Manga?
    @State private var errorText: String?
    @State private var reader: MangaReaderTarget?

    private var current: Manga { detail ?? manga }
    private var chapters: [MangaChapter] { newestFirst ? current.chapters.reversed() : current.chapters }
    private var saved: MangaProgress? { library.progress(for: manga) }

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    MangaCover(manga: current).frame(width: 110, height: 160)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(current.title).font(.title3.weight(.bold))
                        if let author = current.author { Text(author).font(.subheadline).foregroundStyle(.secondary) }
                        if let status = current.status { Text(status).font(.caption).foregroundStyle(.secondary) }
                        Text(MangaCatalog.provider(id: current.providerID)?.name ?? current.providerID)
                            .font(.caption).foregroundStyle(.secondary)
                        if detail != nil {
                            Text("\(current.chapters.count) chapters").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let overview = current.overview {
                    Text(overview).font(.callout).foregroundStyle(.secondary).lineLimit(8)
                }
                if let detail, !detail.chapters.isEmpty {
                    Button {
                        openResume(detail)
                    } label: {
                        Label(resumeTitle(detail), systemImage: "book.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            if detail != nil {
                Section {
                    ForEach(chapters) { chapter in
                        Button {
                            open(chapter, page: saved?.chapterID == chapter.id ? saved?.pageIndex ?? 0 : 0)
                        } label: {
                            chapterRow(chapter)
                        }
                        .swipeActions {
                            let read = library.isRead(chapter, in: current)
                            Button(read ? "Unread" : "Read") {
                                library.setRead(chapter, in: current, read: !read)
                            }
                            .tint(read ? .gray : .accentColor)
                        }
                    }
                } header: {
                    HStack {
                        Text("Chapters")
                        Spacer()
                        Button(newestFirst ? "Newest first" : "Oldest first") { newestFirst.toggle() }
                            .font(.caption)
                            .textCase(nil)
                    }
                }
            }
        }
        .navigationTitle(current.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    library.toggleFavorite(current)
                } label: {
                    Image(systemName: library.isFavorite(current) ? "heart.fill" : "heart")
                }
                .accessibilityLabel(library.isFavorite(current) ? "Remove from favorites" : "Add to favorites")
            }
        }
        .overlay {
            if detail == nil {
                if let errorText {
                    ContentUnavailableView("Couldn't load chapters", systemImage: "exclamationmark.triangle", description: Text(errorText))
                } else {
                    ProgressView()
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .fullScreenCover(item: $reader) { target in
            MangaReaderView(manga: target.manga, chapterIndex: target.chapterIndex, startPage: target.page)
        }
    }

    private func chapterRow(_ chapter: MangaChapter) -> some View {
        let read = library.isRead(chapter, in: current)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(chapter.displayTitle)
                    .foregroundStyle(read ? .secondary : .primary)
                if saved?.chapterID == chapter.id, let page = saved?.pageIndex {
                    Text("Page \(page + 1)").font(.caption).foregroundStyle(.tint)
                }
            }
            Spacer()
            if read { Image(systemName: "checkmark").foregroundStyle(.secondary) }
        }
        .contentShape(Rectangle())
    }

    private func resumeTitle(_ detail: Manga) -> String {
        if let saved, let chapter = detail.chapters.first(where: { $0.id == saved.chapterID }) {
            return "Continue \(chapter.displayTitle)"
        }
        return "Start reading"
    }

    private func openResume(_ detail: Manga) {
        if let saved, let chapter = detail.chapters.first(where: { $0.id == saved.chapterID }) {
            open(chapter, page: saved.pageIndex)
        } else if let first = detail.chapters.first {
            open(first, page: 0)
        }
    }

    private func open(_ chapter: MangaChapter, page: Int) {
        guard let detail, let index = detail.chapters.firstIndex(of: chapter) else { return }
        reader = MangaReaderTarget(manga: detail, chapterIndex: index, page: page)
    }

    private func load() async {
        guard let provider = MangaCatalog.provider(id: manga.providerID) else {
            errorText = "Unknown source \(manga.providerID)"
            return
        }
        do {
            detail = try await provider.manga(id: manga.id)
            errorText = nil
        } catch is CancellationError {
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private struct MangaReaderTarget: Identifiable {
    let id = UUID()
    let manga: Manga
    let chapterIndex: Int
    let page: Int
}

// MARK: Reader

struct MangaReaderView: View {
    let manga: Manga
    @State private var chapterIndex: Int
    @State private var pendingPage: Int?
    @Environment(\.dismiss) private var dismiss
    @AppStorage("manga.reader.paged") private var paged = false
    @State private var pages: [MangaPage] = []
    @State private var currentPage = 0
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var showsChrome = true

    init(manga: Manga, chapterIndex: Int, startPage: Int) {
        self.manga = manga
        _chapterIndex = State(initialValue: chapterIndex)
        _pendingPage = State(initialValue: startPage)
    }

    private var chapter: MangaChapter { manga.chapters[chapterIndex] }
    private var hasPrevious: Bool { chapterIndex > 0 }
    private var hasNext: Bool { chapterIndex + 1 < manga.chapters.count }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if !pages.isEmpty {
                if paged { pagedReader } else { verticalReader }
            } else if isLoading {
                ProgressView().tint(.white)
            } else if let errorText {
                VStack(spacing: 12) {
                    Text(errorText).foregroundStyle(.white).multilineTextAlignment(.center)
                    Button("Retry") { Task { await loadPages() } }.buttonStyle(.borderedProminent)
                }
                .padding()
            }
            if showsChrome { chrome }
        }
        .statusBarHidden(!showsChrome)
        .persistentSystemOverlays(showsChrome ? .automatic : .hidden)
        .task(id: chapterIndex) { await loadPages() }
        .onChange(of: currentPage) { saveProgress() }
        .onDisappear { saveProgress() }
    }

    private var verticalReader: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(pages) { page in
                        MangaRemoteImage(url: page.imageURL, headers: page.headers, contentMode: .fit, placeholderHeight: 520)
                            .id(page.index)
                            .onAppear { currentPage = page.index }
                    }
                    chapterFooter
                }
            }
            .onTapGesture { withAnimation { showsChrome.toggle() } }
            .onAppear { scrollToPending(proxy) }
            .onChange(of: pages) { scrollToPending(proxy) }
            .onChange(of: paged) { proxy.scrollTo(currentPage, anchor: .top) }
        }
    }

    private var pagedReader: some View {
        TabView(selection: $currentPage) {
            ForEach(pages) { page in
                MangaRemoteImage(url: page.imageURL, headers: page.headers, contentMode: .fit)
                    .tag(page.index)
            }
            chapterFooter.tag(pages.count)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .onTapGesture { withAnimation { showsChrome.toggle() } }
    }

    private var chapterFooter: some View {
        VStack(spacing: 14) {
            Text("End of \(chapter.displayTitle)").foregroundStyle(.white.opacity(0.7))
            if hasNext {
                Button("Next: \(manga.chapters[chapterIndex + 1].displayTitle)") { go(to: chapterIndex + 1) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    private var chrome: some View {
        VStack {
            HStack(spacing: 14) {
                Button { dismiss() } label: { Image(systemName: "xmark").font(.headline) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(manga.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(chapter.displayTitle).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
                Spacer()
                Button {
                    paged.toggle()
                } label: {
                    Image(systemName: paged ? "book.pages" : "arrow.up.and.down.text.horizontal")
                }
                .accessibilityLabel(paged ? "Switch to vertical scroll" : "Switch to paged")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.black.opacity(0.75))
            Spacer()
            HStack {
                Button { go(to: chapterIndex - 1) } label: { Image(systemName: "chevron.left") }
                    .disabled(!hasPrevious)
                Spacer()
                Text(pages.isEmpty ? "–" : "\(min(currentPage, pages.count - 1) + 1) / \(pages.count)")
                    .font(.caption.monospacedDigit())
                Spacer()
                Button { go(to: chapterIndex + 1) } label: { Image(systemName: "chevron.right") }
                    .disabled(!hasNext)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.black.opacity(0.75))
        }
        .foregroundStyle(.white)
        .tint(.white)
    }

    private func go(to index: Int) {
        guard manga.chapters.indices.contains(index) else { return }
        saveProgress()
        pendingPage = 0
        pages = []
        currentPage = 0
        chapterIndex = index
    }

    private func scrollToPending(_ proxy: ScrollViewProxy) {
        guard let page = pendingPage, !pages.isEmpty else { return }
        pendingPage = nil
        let target = min(page, pages.count - 1)
        currentPage = target
        if target > 0 { proxy.scrollTo(target, anchor: .top) }
    }

    private func loadPages() async {
        guard let provider = MangaCatalog.provider(id: manga.providerID) else { return }
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do {
            let loaded = try await provider.pages(chapterID: chapter.id)
            pages = loaded.enumerated().map { MangaPage(index: $0.offset, imageURL: $0.element.imageURL, headers: $0.element.headers) }
            if pages.isEmpty { errorText = "No pages found for this chapter." }
            if paged, let page = pendingPage {
                pendingPage = nil
                currentPage = min(page, max(pages.count - 1, 0))
            }
        } catch is CancellationError {
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func saveProgress() {
        guard !pages.isEmpty else { return }
        let page = min(currentPage, pages.count - 1)
        MangaLibrary.shared.save(manga: manga, chapter: chapter, pageIndex: page, finished: currentPage >= pages.count - 1)
    }
}

// MARK: Images

/// Image loader that sends the source's Referer/User-Agent, which most manga
/// CDNs require.
final class MangaImageCache: @unchecked Sendable {
    static let shared = MangaImageCache()
    private let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.totalCostLimit = 150 * 1024 * 1024
        return cache
    }()

    func cached(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

    func image(for url: URL, headers: [String: String]) async throws -> UIImage {
        if let image = cached(url) { return image }
        var request = URLRequest(url: url, timeoutInterval: 30)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status), let image = UIImage(data: data) else {
            throw AppError.providerUnavailable("Image HTTP \(status)")
        }
        cache.setObject(image, forKey: url as NSURL, cost: data.count)
        return image
    }
}

struct MangaRemoteImage: View {
    let url: URL?
    var headers: [String: String] = [:]
    var contentMode: ContentMode = .fill
    var placeholderHeight: CGFloat? = nil
    @State private var image: UIImage?
    @State private var failed = false
    @State private var attempt = 0

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else {
                ZStack {
                    Rectangle().fill(Color.gray.opacity(0.18))
                    if failed {
                        Button { attempt += 1 } label: { Image(systemName: "arrow.clockwise") }
                            .foregroundStyle(.secondary)
                    } else if url != nil {
                        ProgressView()
                    } else {
                        Image(systemName: "book.closed").foregroundStyle(.secondary)
                    }
                }
                .frame(height: placeholderHeight)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: contentMode == .fill ? .infinity : nil)
        .clipped()
        .task(id: "\(url?.absoluteString ?? "")#\(attempt)") {
            guard let url else { return }
            if let cached = MangaImageCache.shared.cached(url) {
                image = cached
                return
            }
            image = nil
            failed = false
            do {
                image = try await MangaImageCache.shared.image(for: url, headers: headers)
            } catch {
                if !Task.isCancelled { failed = true }
            }
        }
    }
}
