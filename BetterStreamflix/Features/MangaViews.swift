import SwiftUI
import UIKit

enum MangaRoute: Hashable {
    case detail(Manga)
}

// MARK: Browser

struct MangaHomeView: View {
    @EnvironmentObject private var environment: AppEnvironment
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
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                sourceChips
                if trimmedQuery.isEmpty {
                    if let hero = categories.first?.items.first {
                        MangaHeroCard(manga: hero, caption: categories.first?.name ?? "Featured", providerName: provider.name)
                            .padding(.horizontal, DesignTokens.Spacing.screenHorizontal)
                    }
                    if !library.progress.isEmpty {
                        MangaShelf(title: "Continue Reading", items: library.progress.map(\.manga)) { manga in
                            library.progress(for: manga)?.chapterTitle
                        }
                    }
                    if !library.favorites.isEmpty {
                        MangaShelf(title: "Favorites", items: library.favorites)
                    }
                    ForEach(Array(categories.enumerated()), id: \.element.id) { index, category in
                        MangaShelf(title: category.name, items: index == 0 ? Array(category.items.dropFirst()) : category.items)
                    }
                    if categories.isEmpty { statusView }
                } else if results.isEmpty {
                    statusView
                } else {
                    LazyVGrid(columns: MediaArtworkLayout.gridColumns, spacing: 18) {
                        ForEach(results) { manga in
                            NavigationLink(value: MangaRoute.detail(manga)) { MangaGridCard(manga: manga) }
                                .buttonStyle(PressablePosterButtonStyle())
                        }
                    }
                    .padding(.horizontal, MediaArtworkLayout.gridHorizontalPadding)
                }
            }
            .padding(.bottom, 120)
        }
        .scrollIndicators(.hidden)
        .background { AppScreenBackground() }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search \(provider.name)")
        .task(id: providerID) { await loadHome() }
        .task(id: "\(providerID)|\(trimmedQuery)") { await search() }
        .refreshable { await loadHome() }
        .navigationDestination(for: MangaRoute.self) { route in
            switch route {
            case .detail(let manga): MangaDetailView(manga: manga)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Manga")
                .font(.system(size: 38, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.55), radius: 12, y: 3)
            Text(trimmedQuery.isEmpty ? "Read chapters from \(MangaCatalog.all.count) sources" : "Results from \(provider.name)")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, DesignTokens.Spacing.screenHorizontal)
        .padding(.top, 4)
    }

    private var sourceChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MangaCatalog.all, id: \.id) { source in
                    let selected = source.id == providerID
                    Button {
                        DesignTokens.Haptics.selection()
                        withAnimation(DesignTokens.Motion.soft) { providerID = source.id }
                    } label: {
                        Text(source.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(selected ? Color(hex: 0x11141C) : .white.opacity(0.85))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background {
                                if selected {
                                    Capsule().fill(environment.theme.accentBright)
                                } else {
                                    Capsule().fill(AppTheme.surface).overlay(Capsule().stroke(AppTheme.border, lineWidth: 1))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.screenHorizontal)
        }
    }

    @ViewBuilder
    private var statusView: some View {
        VStack(spacing: 12) {
            if isLoading {
                ProgressView().tint(.white)
                Text("Loading \(provider.name)…").font(DesignTokens.Typography.caption).foregroundStyle(.white.opacity(0.6))
            } else {
                Image(systemName: trimmedQuery.isEmpty ? "books.vertical" : "magnifyingglass")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(environment.theme.accentBright)
                Text(trimmedQuery.isEmpty ? "Couldn't load \(provider.name)" : "No results for “\(trimmedQuery)”")
                    .font(.headline).foregroundStyle(.white)
                if let errorText {
                    Text(errorText).font(.caption).foregroundStyle(.white.opacity(0.55)).multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .padding(.horizontal, 32)
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

/// Artwork-first feature card: blurred cover backdrop, large cover, title and
/// a primary Read action, like the home screen's hero.
private struct MangaHeroCard: View {
    @EnvironmentObject private var environment: AppEnvironment
    let manga: Manga
    let caption: String
    let providerName: String

    var body: some View {
        NavigationLink(value: MangaRoute.detail(manga)) {
            Group {
                HStack(alignment: .bottom, spacing: 16) {
                    MangaCover(manga: manga)
                        .frame(width: 128, height: 192)
                        .shadow(color: DesignTokens.Elevation.posterShadow, radius: 16, y: 8)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(caption.uppercased())
                            .font(.caption2.weight(.bold))
                            .tracking(1.2)
                            .foregroundStyle(environment.theme.accentBright)
                        Text(manga.title)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                        Text(providerName)
                            .font(DesignTokens.Typography.metadata)
                            .foregroundStyle(.white.opacity(0.65))
                        HStack(spacing: 6) {
                            Image(systemName: "book.fill")
                            Text("Read")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(hex: 0x11141C))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(LinearGradient(colors: [Color(hex: 0xF7F9FF), Color(hex: 0xCBD3E1)], startPoint: .top, endPoint: .bottom)))
                        .shadow(color: environment.theme.accent.opacity(0.45), radius: 10, y: 3)
                    }
                    Spacer(minLength: 0)
                }
                .padding(18)
            }
            .frame(maxWidth: .infinity, minHeight: 250, alignment: .bottomLeading)
            .background {
                // Backdrop must not take part in layout, or fill-mode artwork widens the card.
                ZStack {
                    MangaCover(manga: manga, cornerRadius: 0)
                        .blur(radius: 28)
                        .scaleEffect(1.3)
                        .opacity(0.7)
                    LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sheet, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.sheet, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
        }
        .buttonStyle(PressablePosterButtonStyle())
    }
}

/// Horizontal cover shelf matching MediaShelfView's title and poster sizes.
private struct MangaShelf: View {
    @EnvironmentObject private var environment: AppEnvironment
    let title: String
    let items: [Manga]
    var caption: (Manga) -> String? = { _ in nil }

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(DesignTokens.Typography.shelfTitle).foregroundStyle(.white)
                    Spacer()
                    Text("\(items.count)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(environment.theme.accentBright)
                }
                .padding(.horizontal, DesignTokens.Spacing.screenHorizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(items, id: \.self) { manga in
                            NavigationLink(value: MangaRoute.detail(manga)) {
                                MangaPosterCard(manga: manga, caption: caption(manga))
                            }
                            .buttonStyle(PressablePosterButtonStyle())
                        }
                    }
                    .padding(.horizontal, DesignTokens.Spacing.screenHorizontal)
                }
            }
        }
    }
}

private struct MangaPosterCard: View {
    let manga: Manga
    var caption: String?
    private let width = MediaArtworkLayout.shelfPosterWidth

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            MangaCover(manga: manga)
                .frame(width: width, height: width * 1.5)
            Text(manga.title)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: width, alignment: .leading)
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
                    .frame(width: width, alignment: .leading)
            }
        }
        .foregroundStyle(.white)
    }
}

private struct MangaGridCard: View {
    let manga: Manga

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay { MangaCover(manga: manga, cornerRadius: 0) }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(manga.title)
                .font(.caption.weight(.semibold))
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(.white)
    }
}

private struct MangaCover: View {
    let manga: Manga
    var cornerRadius: CGFloat = DesignTokens.Radius.poster

    var body: some View {
        MangaRemoteImage(
            url: manga.cover,
            headers: MangaCatalog.provider(id: manga.providerID)?.imageHeaders ?? [:],
            contentMode: .fill
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

// MARK: Chapters

struct MangaDetailView: View {
    let manga: Manga
    @ObservedObject private var library = MangaLibrary.shared
    @ObservedObject private var downloads = MangaDownloadManager.shared
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
                            if let download = downloads.item(current, chapter) {
                                Button("Remove", role: .destructive) { downloads.remove(download.id) }
                            } else {
                                Button("Download") { downloads.download(chapter, of: current) }
                                    .tint(.blue)
                            }
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
                if let detail, !detail.chapters.isEmpty {
                    downloadMenu(detail)
                }
            }
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
            downloadBadge(chapter)
            if read { Image(systemName: "checkmark").foregroundStyle(.secondary) }
        }
        .contentShape(Rectangle())
    }

    private func downloadMenu(_ detail: Manga) -> some View {
        let unread = detail.chapters.filter { !library.isRead($0, in: detail) }
        let hasDownloads = downloads.items.contains { MangaLibrary.key($0.manga) == MangaLibrary.key(detail) }
        return Menu {
            Button("Download unread (\(unread.count))", systemImage: "arrow.down.circle") {
                downloads.downloadAll(unread, of: detail)
            }
            .disabled(unread.isEmpty)
            Button("Download all (\(detail.chapters.count))", systemImage: "arrow.down.circle.dotted") {
                downloads.downloadAll(detail.chapters, of: detail)
            }
            if hasDownloads {
                Button("Remove downloads", systemImage: "trash", role: .destructive) {
                    downloads.removeAll(for: detail)
                }
            }
        } label: {
            Image(systemName: "arrow.down.circle")
        }
        .accessibilityLabel("Download chapters")
    }

    @ViewBuilder
    private func downloadBadge(_ chapter: MangaChapter) -> some View {
        if let download = downloads.item(current, chapter) {
            switch download.state {
            case .completed:
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.secondary)
                    .accessibilityLabel("Downloaded")
            case .queued, .downloading:
                ProgressView(value: download.progress).frame(width: 36)
            case .failed:
                Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
                    .accessibilityLabel("Download failed")
            }
        }
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
            // Offline: fall back to the chapters downloaded for this title.
            let saved = downloads.completed(for: manga)
            if detail == nil, !saved.isEmpty {
                var offline = manga
                offline.chapters = saved.map(\.chapter)
                detail = offline
            } else {
                errorText = error.localizedDescription
            }
        }
    }
}

struct MangaReaderTarget: Identifiable {
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
                ZoomableMangaPage(page: page) { withAnimation { showsChrome.toggle() } }
                    .ignoresSafeArea()
                    .tag(page.index)
            }
            chapterFooter.tag(pages.count)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
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
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do {
            let loaded: [MangaPage]
            if let local = MangaDownloadManager.shared.localPages(for: manga, chapter: chapter) {
                loaded = local
            } else {
                guard let provider = MangaCatalog.provider(id: manga.providerID) else {
                    throw AppError.providerUnavailable("Unknown source \(manga.providerID)")
                }
                loaded = try await provider.pages(chapterID: chapter.id)
            }
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

// MARK: Downloads

/// Manga chapters in the Library's Downloads list; finished ones open in the
/// reader from disk.
struct MangaDownloadsSection: View {
    @ObservedObject private var downloads = MangaDownloadManager.shared
    @Binding var reader: MangaReaderTarget?

    var body: some View {
        if !downloads.items.isEmpty {
            Section {
                ForEach(downloads.items) { item in
                    Button { open(item) } label: { row(item) }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) { downloads.remove(item.id) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            } header: {
                Text("Manga")
            } footer: {
                Text("\(ByteCountFormatter.string(fromByteCount: downloads.totalBytesOnDisk, countStyle: .file)) of manga on this device")
            }
        }
    }

    private func row(_ item: MangaChapterDownload) -> some View {
        HStack(spacing: 12) {
            MangaCover(manga: item.manga).frame(width: 40, height: 58)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.manga.title).font(.headline).foregroundStyle(AppTheme.primaryText).lineLimit(1)
                Text(item.chapter.displayTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                switch item.state {
                case .queued:
                    Text("Queued").font(.caption2).foregroundStyle(.secondary)
                case .downloading:
                    ProgressView(value: item.progress)
                    Text("\(item.pagesDone) of \(item.pageCount) pages").font(.caption2).foregroundStyle(.secondary)
                case .completed:
                    Text("Downloaded · \(item.pageCount) pages · \(ByteCountFormatter.string(fromByteCount: item.bytesOnDisk, countStyle: .file))")
                        .font(.caption2).foregroundStyle(.secondary)
                case .failed:
                    Text(item.errorMessage ?? "Download failed").font(.caption2).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            switch item.state {
            case .completed:
                Image(systemName: "book.circle.fill").font(.title2).foregroundStyle(.secondary)
            case .failed:
                Button { downloads.retry(item.id) } label: { Image(systemName: "arrow.clockwise.circle.fill").font(.title2) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Retry download")
            case .queued, .downloading:
                Button { downloads.cancel(item.id) } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Cancel download")
            }
        }
        .contentShape(Rectangle())
    }

    private func open(_ item: MangaChapterDownload) {
        guard item.state == .completed else { return }
        let saved = downloads.completed(for: item.manga)
        guard let index = saved.firstIndex(where: { $0.id == item.id }) else { return }
        var manga = item.manga
        manga.chapters = saved.map(\.chapter)
        let progress = MangaLibrary.shared.progress(for: manga)
        let page = progress?.chapterID == item.chapter.id ? progress?.pageIndex ?? 0 : 0
        reader = MangaReaderTarget(manga: manga, chapterIndex: index, page: page)
    }
}

// MARK: Zoom

/// Paged-mode page: pinch or double-tap to zoom (up to 4x), pan while zoomed.
/// At 1x the scroll view has nothing to scroll, so swipes still turn pages.
struct ZoomableMangaPage: UIViewRepresentable {
    let page: MangaPage
    var onTap: () -> Void

    func makeUIView(context: Context) -> ZoomableImageScrollView {
        let view = ZoomableImageScrollView()
        view.onTap = onTap
        view.load(page)
        return view
    }

    func updateUIView(_ view: ZoomableImageScrollView, context: Context) {
        view.onTap = onTap
        if view.pageURL != page.imageURL { view.load(page) }
    }
}

final class ZoomableImageScrollView: UIScrollView, UIScrollViewDelegate {
    private(set) var pageURL: URL?
    var onTap: (() -> Void)?
    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var loadTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 4
        bouncesZoom = true
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
        spinner.color = .white
        spinner.hidesWhenStopped = true
        addSubview(spinner)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { loadTask?.cancel() }

    func load(_ page: MangaPage) {
        pageURL = page.imageURL
        setZoomScale(1, animated: false)
        loadTask?.cancel()
        if let cached = MangaImageCache.shared.cached(page.imageURL) {
            imageView.image = cached
            spinner.stopAnimating()
            return
        }
        imageView.image = nil
        spinner.startAnimating()
        let url = page.imageURL
        loadTask = Task { @MainActor [weak self] in
            let image = try? await MangaImageCache.shared.image(for: url, headers: page.headers)
            guard let self, !Task.isCancelled, self.pageURL == url else { return }
            self.spinner.stopAnimating()
            self.imageView.image = image ?? UIImage(systemName: "exclamationmark.triangle")
            self.imageView.tintColor = .gray
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if zoomScale == 1 {
            imageView.frame = bounds
            contentSize = bounds.size
        }
        spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    @objc private func handleSingleTap() { onTap?() }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let scale: CGFloat = 2.5
        let point = gesture.location(in: imageView)
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
    }
}

// MARK: Images

/// Image loader that sends the source's Referer/User-Agent, which most manga
/// CDNs require. Hosts behind a Cloudflare check reuse the stored clearance
/// (cookies + matching WebView user agent) and get one WebView pass on a block.
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
        let (data, _) = try await data(for: url, headers: headers)
        guard let image = UIImage(data: data) else { throw AppError.decoding("Not an image") }
        cache.setObject(image, forKey: url as NSURL, cost: data.count)
        return image
    }

    /// Raw image bytes plus a file extension, for display and offline copies.
    func data(for url: URL, headers: [String: String]) async throws -> (Data, String) {
        if url.isFileURL {
            return (try Data(contentsOf: url), url.pathExtension)
        }
        var merged = headers
        if let clearance = await CloudflareResolver.shared.cachedClearance(for: url) {
            merged.merge(clearance.headers) { _, cleared in cleared }
        }
        var (data, response) = try await fetch(url, headers: merged)
        if Self.isBlocked(data: data, response: response) {
            let clearance = try await CloudflareResolver.shared.clearance(for: url)
            merged.merge(clearance.headers) { _, cleared in cleared }
            (data, response) = try await fetch(url, headers: merged)
        }
        let status = response?.statusCode ?? 0
        guard (200...299).contains(status) else { throw AppError.providerUnavailable("Image HTTP \(status)") }
        return (data, Self.fileExtension(response: response, url: url))
    }

    private func fetch(_ url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse?) {
        var request = URLRequest(url: url, timeoutInterval: 30)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, response as? HTTPURLResponse)
    }

    private static func isBlocked(data: Data, response: HTTPURLResponse?) -> Bool {
        let status = response?.statusCode ?? 0
        let type = response?.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard status == 403 || status == 503 || type.contains("text/html") else { return false }
        let text = String(decoding: data.prefix(64 * 1024), as: UTF8.self)
        return CloudflareResolver.isChallenge(statusCode: status, html: text) && !CloudflareResolver.isHardBlock(text)
            && (response?.value(forHTTPHeaderField: "Server")?.lowercased().contains("cloudflare") ?? true)
    }

    private static func fileExtension(response: HTTPURLResponse?, url: URL) -> String {
        switch response?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? "" {
        case let type where type.contains("png"): return "png"
        case let type where type.contains("webp"): return "webp"
        case let type where type.contains("gif"): return "gif"
        case let type where type.contains("jpeg"), let type where type.contains("jpg"): return "jpg"
        default:
            let ext = url.pathExtension.lowercased()
            return ["jpg", "jpeg", "png", "webp", "gif"].contains(ext) ? ext : "jpg"
        }
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
