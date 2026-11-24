import Foundation

// MARK: Models

struct Manga: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var title: String
    var cover: URL?
    var overview: String?
    var author: String?
    var status: String?
    var providerID: String
    var chapters: [MangaChapter] = []

    /// The same title without its chapter list, for favorites and progress.
    var summary: Manga {
        var copy = self
        copy.chapters = []
        return copy
    }
}

struct MangaChapter: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var number: Double
    var title: String?

    var numberLabel: String {
        number.rounded() == number ? String(Int(number)) : String(format: "%g", number)
    }

    var displayTitle: String {
        guard let title, !title.isEmpty else { return "Chapter \(numberLabel)" }
        return title
    }
}

struct MangaPage: Identifiable, Hashable, Sendable {
    let index: Int
    let imageURL: URL
    var headers: [String: String] = [:]

    var id: Int { index }
}

struct MangaCategory: Identifiable, Sendable {
    let name: String
    let items: [Manga]

    var id: String { name }
}

/// Manga sources, kept separate from playback providers like Android's
/// `MangaProvider` list.
protocol MangaProvider: Sendable {
    var id: String { get }
    var name: String { get }
    var baseURL: URL { get }
    var language: String { get }
    var logo: URL? { get }

    func home() async throws -> [MangaCategory]
    func search(_ query: String) async throws -> [Manga]
    func manga(id: String) async throws -> Manga
    func pages(chapterID: String) async throws -> [MangaPage]
}

extension MangaProvider {
    var imageHeaders: [String: String] {
        ["User-Agent": MangaHTTP.userAgent, "Referer": baseURL.absoluteString + "/"]
    }
}

enum MangaCatalog {
    static let all: [any MangaProvider] = [
        MangaFreakMangaProvider(),
        FlameComicsMangaProvider(),
        WeebCentralMangaProvider(),
        MangaHereMangaProvider(),
        MadaraMangaProvider(
            id: "manhuaplus",
            name: "ManhuaPlus",
            baseURL: URL(string: "https://manhuaplus.com")!,
            logo: URL(string: "https://manhuaplus.com/wp-content/uploads/2017/10/logo-1-1.png")
        ),
        MadaraMangaProvider(
            id: "toonily",
            name: "Toonily",
            baseURL: URL(string: "https://toonily.com")!,
            logo: URL(string: "https://toonily.com/favicon.ico"),
            mangaPath: "/serie",
            usesCloudflare: true
        ),
    ]

    static func provider(id: String) -> (any MangaProvider)? {
        all.first { $0.id == id }
    }

    /// Search → detail → pages for every provider; used by `-mangaSmoke`.
    static func smoke() async -> [String] {
        let queries = ["flamecomics": "omniscient", "manhuaplus": "martial", "toonily": "love"]
        return await withTaskGroup(of: String.self) { group in
            for provider in all {
                group.addTask {
                    let query = queries[provider.id] ?? "one piece"
                    do {
                        let home = try await provider.home()
                        let results = try await provider.search(query)
                        guard let first = results.first else {
                            return "MANGA FAIL \(provider.id) home=\(home.map(\.items.count)) search=0"
                        }
                        let detail = try await provider.manga(id: first.id)
                        guard let chapter = detail.chapters.last else {
                            return "MANGA FAIL \(provider.id) \"\(detail.title)\" chapters=0"
                        }
                        let pages = try await provider.pages(chapterID: chapter.id)
                        let ok = !pages.isEmpty
                        return "MANGA \(ok ? "PASS" : "FAIL") \(provider.id) home=\(home.map(\.items.count)) search=\(results.count) \"\(detail.title)\" chapters=\(detail.chapters.count) ch\(chapter.numberLabel) pages=\(pages.count) \(pages.first?.imageURL.absoluteString ?? "")"
                    } catch {
                        return "MANGA FAIL \(provider.id) \(error.localizedDescription)"
                    }
                }
            }
            var lines: [String] = []
            for await line in group { lines.append(line) }
            return lines.sorted()
        }
    }
}

// MARK: Shared helpers

enum MangaHTTP {
    static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"

    static func text(
        _ url: URL,
        headers: [String: String] = [:],
        method: String = "GET",
        form: [String: String]? = nil
    ) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let form {
            request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = form.map { "\(encode($0.key))=\(encode($0.value))" }
                .joined(separator: "&").data(using: .utf8)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            throw AppError.providerUnavailable("HTTP \(status) for \(url.host ?? url.absoluteString)")
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func encode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

private func nonBlank(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
    return trimmed
}

private func capture(_ pattern: String, in text: String, group: Int = 1) -> String? {
    guard let match = AnimeHTML.captures(pattern, in: text).first, match.count > group else { return nil }
    return nonBlank(match[group])
}

private func absoluteURL(_ value: String, base: URL) -> URL? {
    guard let value = nonBlank(value) else { return nil }
    if value.hasPrefix("//") { return URL(string: "https:" + value) }
    return URL(string: value, relativeTo: base)?.absoluteURL
}

private func metaContent(_ property: String, in html: String) -> String? {
    let escaped = NSRegularExpression.escapedPattern(for: property)
    let raw = capture(#"<meta[^>]*(?:property|name)=["']"# + escaped + #"["'][^>]*content=["']([^"']*)["']"#, in: html)
        ?? capture(#"<meta[^>]*content=["']([^"']*)["'][^>]*(?:property|name)=["']"# + escaped + #"["']"#, in: html)
    return raw.map(HTMLPayloadParser.decodeEntities)
}

private func slugTitle(_ url: URL) -> String {
    url.lastPathComponent.replacingOccurrences(of: "_", with: " ")
        .replacingOccurrences(of: "-", with: " ").capitalized
}

private func lastNumber(_ text: String) -> Double? {
    AnimeHTML.captures(#"(\d+(?:\.\d+)?)"#, in: text).last.flatMap { Double($0[1]) }
}

/// Collects cards in page order, merging duplicate links (e.g. a cover link and
/// a title link for the same series) instead of dropping the later one.
private struct MangaCardList {
    private(set) var items: [Manga] = []
    private var index: [String: Int] = [:]

    mutating func add(_ manga: Manga, titleIsFallback: Bool = false) {
        if let position = index[manga.id] {
            if items[position].cover == nil { items[position].cover = manga.cover }
            if !titleIsFallback, fallbackIDs.contains(manga.id) {
                items[position].title = manga.title
                fallbackIDs.remove(manga.id)
            }
            return
        }
        index[manga.id] = items.count
        items.append(manga)
        if titleIsFallback { fallbackIDs.insert(manga.id) }
    }

    private var fallbackIDs: Set<String> = []
}

private func imageSource(_ node: AnimeHTML?, base: URL) -> URL? {
    guard let node else { return nil }
    for key in ["data-src", "data-lazy-src", "src", "srcset"] {
        let value = node[key].components(separatedBy: " ").first ?? ""
        if let url = absoluteURL(value, base: base), url.scheme?.hasPrefix("http") == true,
           !value.hasPrefix("data:") { return url }
    }
    return nil
}

private extension AnimeHTML {
    func elements(_ tag: String) -> [AnimeHTML] { all { $0.tag == tag } }
}

// MARK: MangaFreak

struct MangaFreakMangaProvider: MangaProvider {
    let id = "mangafreak"
    let name = "MangaFreak"
    let baseURL = URL(string: "https://ww3.mangafreak.me")!
    let language = "en"
    var logo: URL? { baseURL.appendingPathComponent("images/logo.png") }

    private func parseItems(_ html: String) -> [Manga] {
        var cards = MangaCardList()
        for anchor in AnimeHTML.parse(html).elements("a") where anchor["href"].contains("/Manga/") {
            guard let url = absoluteURL(anchor["href"], base: baseURL) else { continue }
            let image = anchor.first { $0.tag == "img" }
            let text = anchor.text.count < 100 ? nonBlank(anchor.text) : nil
            let title = nonBlank(anchor["title"]) ?? nonBlank(image?["alt"]) ?? text
            cards.add(
                Manga(id: url.absoluteString, title: title ?? slugTitle(url), cover: imageSource(image, base: baseURL), providerID: id),
                titleIsFallback: title == nil
            )
        }
        return cards.items
    }

    func home() async throws -> [MangaCategory] {
        let html = try await MangaHTTP.text(baseURL)
        let document = AnimeHTML.parse(html)
        var latest = MangaCardList()
        for item in document.all({ $0.hasClass("latest_item") }) {
            guard let anchor = item.first({ $0.tag == "a" && $0["href"].contains("/Manga/") }),
                  let url = absoluteURL(anchor["href"], base: baseURL) else { continue }
            let title = nonBlank(item.first { $0.tag == "a" && $0.hasClass("name") }?.text) ?? nonBlank(anchor["title"])
            latest.add(Manga(
                id: url.absoluteString,
                title: title ?? slugTitle(url),
                cover: imageSource(anchor.first { $0.tag == "img" }, base: baseURL),
                providerID: id
            ))
        }
        let latestIDs = Set(latest.items.map(\.id))
        let popular = parseItems(html).filter { !latestIDs.contains($0.id) }
        var categories: [MangaCategory] = []
        if !latest.items.isEmpty { categories.append(MangaCategory(name: "Latest Updates", items: latest.items)) }
        if !popular.isEmpty { categories.append(MangaCategory(name: "Popular", items: popular)) }
        return categories
    }

    func search(_ query: String) async throws -> [Manga] {
        guard let term = nonBlank(query) else { return [] }
        let path = term.replacingOccurrences(of: " ", with: "_")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? term
        guard let url = URL(string: baseURL.absoluteString + "/Find/" + path) else { return [] }
        return parseItems(try await MangaHTTP.text(url))
    }

    func manga(id mangaID: String) async throws -> Manga {
        guard let url = URL(string: mangaID) else { throw AppError.invalidURL }
        let html = try await MangaHTTP.text(url)
        let document = AnimeHTML.parse(html)
        let title = nonBlank(document.first { $0.tag == "h1" }?.text)
            ?? metaContent("og:title", in: html)?.components(separatedBy: " - ").first
            ?? slugTitle(url)
        let cover = metaContent("og:image", in: html).flatMap { absoluteURL($0, base: baseURL) }
            ?? imageSource(document.first { $0.tag == "img" && $0["src"].contains("manga_images") }, base: baseURL)
        var seen = Set<String>()
        let chapters = AnimeHTML.captures(#"/Read1_[^"'\s<>]+"#, in: html).compactMap { match -> MangaChapter? in
            let path = match[0]
            guard seen.insert(path).inserted,
                  let numbers = AnimeHTML.captures(#"_(\d+)(?:e(\d+))?$"#, in: path).first,
                  let whole = Double(numbers[1]),
                  let chapterURL = absoluteURL(path, base: baseURL) else { return nil }
            let number = numbers[2].isEmpty ? whole : Double("\(numbers[1]).\(numbers[2])") ?? whole
            return MangaChapter(id: chapterURL.absoluteString, number: number, title: nil)
        }.sorted { $0.number < $1.number }
        return Manga(
            id: mangaID,
            title: title,
            cover: cover,
            overview: metaContent("description", in: html),
            providerID: id,
            chapters: chapters
        )
    }

    func pages(chapterID: String) async throws -> [MangaPage] {
        guard let url = URL(string: chapterID) else { throw AppError.invalidURL }
        let document = AnimeHTML.parse(try await MangaHTTP.text(url))
        var seen = Set<String>()
        let urls = document.elements("img").compactMap { imageSource($0, base: baseURL) }
            .filter { $0.absoluteString.contains("/mangas/") && $0.absoluteString.hasSuffix(".jpg") }
            .filter { seen.insert($0.absoluteString).inserted }
            .sorted { pageNumber($0) < pageNumber($1) }
        return urls.enumerated().map { MangaPage(index: $0.offset, imageURL: $0.element, headers: imageHeaders) }
    }

    private func pageNumber(_ url: URL) -> Int {
        capture(#"_(\d+)\.jpg$"#, in: url.absoluteString).flatMap(Int.init) ?? .max
    }
}

// MARK: FlameComics

struct FlameComicsMangaProvider: MangaProvider {
    let id = "flamecomics"
    let name = "FlameComics"
    let baseURL = URL(string: "https://flamecomics.xyz")!
    let language = "en"
    var logo: URL? { baseURL.appendingPathComponent("favicon.ico") }
    private let cdn = "https://cdn.flamecomics.xyz/uploads/images/series"

    private func pageProps(_ url: URL) async throws -> [String: Any]? {
        let html = try await MangaHTTP.text(url)
        guard let raw = AnimeHTML.captures(#"<script id="__NEXT_DATA__"[^>]*>(.*?)</script>"#, in: html).first?[1],
              let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let props = object["props"] as? [String: Any] else { return nil }
        return props["pageProps"] as? [String: Any]
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let text as String: return nonBlank(text)
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    private func cover(seriesID: String, file: String?) -> URL? {
        URL(string: "\(cdn)/\(seriesID)/\(file ?? "thumbnail.webp")")
    }

    private func manga(from series: [String: Any]) -> Manga? {
        guard let seriesID = Self.string(series["series_id"]), let title = Self.string(series["title"]) else { return nil }
        let overview = Self.string(series["description"])?
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        return Manga(
            id: "\(baseURL.absoluteString)/series/\(seriesID)",
            title: HTMLPayloadParser.decodeEntities(title),
            cover: cover(seriesID: seriesID, file: Self.string(series["cover"])),
            overview: nonBlank(overview),
            status: Self.string(series["status"]),
            providerID: id
        )
    }

    private func blockSeries(_ props: [String: Any], key: String) -> [Manga] {
        guard let section = props[key] as? [String: Any],
              let blocks = section["blocks"] as? [[String: Any]] else { return [] }
        var cards = MangaCardList()
        for block in blocks {
            for series in block["series"] as? [[String: Any]] ?? [] {
                if let manga = manga(from: series) { cards.add(manga) }
            }
        }
        return cards.items
    }

    func home() async throws -> [MangaCategory] {
        guard let props = try await pageProps(baseURL) else { return [] }
        return [("latestEntries", "Latest"), ("popularEntries", "Popular"), ("staffPicks", "Staff Picks")]
            .compactMap { key, name in
                let items = blockSeries(props, key: key)
                return items.isEmpty ? nil : MangaCategory(name: name, items: items)
            }
    }

    func search(_ query: String) async throws -> [Manga] {
        guard let term = nonBlank(query),
              let url = URL(string: "\(baseURL.absoluteString)/browse?search=\(MangaHTTP.encode(term))"),
              let props = try await pageProps(url) else { return [] }
        let needle = term.lowercased()
        return (props["series"] as? [[String: Any]] ?? [])
            .filter {
                (Self.string($0["title"]) ?? "").lowercased().contains(needle)
                    || (Self.string($0["description"]) ?? "").lowercased().contains(needle)
            }
            .compactMap(manga(from:))
    }

    func manga(id mangaID: String) async throws -> Manga {
        guard let url = URL(string: mangaID) else { throw AppError.invalidURL }
        guard let props = try await pageProps(url) else { throw AppError.invalidResponse }
        let series = props["series"] as? [String: Any] ?? [:]
        let seriesID = Self.string(series["series_id"]) ?? url.lastPathComponent
        let chapters = (props["chapters"] as? [[String: Any]] ?? []).enumerated().compactMap { offset, chapter -> MangaChapter? in
            guard let token = Self.string(chapter["token"]) else { return nil }
            return MangaChapter(
                id: "\(mangaID)/\(token)",
                number: Self.string(chapter["chapter"]).flatMap(Double.init) ?? Double(offset + 1),
                title: Self.string(chapter["title"]).map(HTMLPayloadParser.decodeEntities)
            )
        }.sorted { $0.number < $1.number }
        var result = manga(from: series) ?? Manga(id: mangaID, title: "", providerID: id)
        result.id = mangaID
        result.cover = cover(seriesID: seriesID, file: Self.string(series["cover"]))
        result.author = Self.string(series["author"])
        result.chapters = chapters
        return result
    }

    func pages(chapterID: String) async throws -> [MangaPage] {
        guard let url = URL(string: chapterID),
              let props = try await pageProps(url),
              let chapter = props["chapter"] as? [String: Any],
              let images = chapter["images"] as? [String: Any] else { return [] }
        let seriesID = Self.string(chapter["series_id"]) ?? ""
        let token = Self.string(chapter["token"]) ?? url.lastPathComponent
        let suffix = Self.string(chapter["edit_time"]).map { "?\($0)" } ?? ""
        return images.keys.compactMap(Int.init).sorted().compactMap { index -> MangaPage? in
            guard let image = images[String(index)] as? [String: Any],
                  let file = Self.string(image["name"]),
                  let imageURL = URL(string: "\(cdn)/\(seriesID)/\(token)/\(file)\(suffix)") else { return nil }
            return MangaPage(index: index, imageURL: imageURL, headers: imageHeaders)
        }
    }
}

// MARK: WeebCentral

struct WeebCentralMangaProvider: MangaProvider {
    let id = "weebcentral"
    let name = "WeebCentral"
    let baseURL = URL(string: "https://weebcentral.com")!
    let language = "en"
    var logo: URL? { baseURL.appendingPathComponent("static/images/brand.png") }
    private let coverBase = "https://temp.compsci88.com/cover/normal"

    private func seriesULID(_ value: String) -> String? {
        capture(#"/series/([0-9A-Z]+)"#, in: value)
    }

    private func parseCards(_ html: String) -> [Manga] {
        var cards = MangaCardList()
        for anchor in AnimeHTML.parse(html).elements("a") {
            guard let path = capture(#"(/series/[0-9A-Z]+/[^"'?#\s]+)"#, in: anchor["href"]),
                  let url = absoluteURL(path, base: baseURL) else { continue }
            let alt = anchor.first { $0.tag == "img" && !$0["alt"].isEmpty }?["alt"]
            let title = nonBlank(alt.map { $0.hasSuffix(" cover") ? String($0.dropLast(6)) : $0 })
                ?? nonBlank(anchor.first { $0.hasClass("truncate") && $0.hasClass("text-white") }?.text)
                ?? nonBlank(anchor["data-tip"])
            let cover = seriesULID(path).flatMap { URL(string: "\(coverBase)/\($0).webp") }
                ?? imageSource(anchor.first { $0.tag == "img" || $0.tag == "source" }, base: baseURL)
            cards.add(
                Manga(id: url.absoluteString, title: title.map(HTMLPayloadParser.decodeEntities) ?? slugTitle(url), cover: cover, providerID: id),
                titleIsFallback: title == nil
            )
        }
        return cards.items
    }

    func home() async throws -> [MangaCategory] {
        let latest = parseCards(try await MangaHTTP.text(baseURL))
        return latest.isEmpty ? [] : [MangaCategory(name: "Latest Updates", items: latest)]
    }

    func search(_ query: String) async throws -> [Manga] {
        guard let term = nonBlank(query),
              let url = URL(string: "\(baseURL.absoluteString)/search/data?text=\(MangaHTTP.encode(term))&limit=24&display_mode=Full%20Display") else { return [] }
        return parseCards(try await MangaHTTP.text(url, headers: ["HX-Request": "true"]))
    }

    func manga(id mangaID: String) async throws -> Manga {
        guard let url = URL(string: mangaID) else { throw AppError.invalidURL }
        let html = try await MangaHTTP.text(url)
        let document = AnimeHTML.parse(html)
        let title = nonBlank(document.first { $0.tag == "h1" }?.text)
            ?? metaContent("og:title", in: html)?.components(separatedBy: " - ").first
            ?? slugTitle(url)
        let ulid = seriesULID(mangaID)
        let cover = ulid.flatMap { URL(string: "\(coverBase)/\($0).webp") }
            ?? metaContent("og:image", in: html).flatMap(URL.init(string:))
        var chapters: [MangaChapter] = []
        if let ulid, let listURL = URL(string: "\(baseURL.absoluteString)/series/\(ulid)/full-chapter-list") {
            var seen = Set<String>()
            for anchor in AnimeHTML.parse(try await MangaHTTP.text(listURL, headers: ["HX-Request": "true"])).elements("a") {
                guard let path = capture(#"(/chapters/[0-9A-Z]+)"#, in: anchor["href"]),
                      seen.insert(path).inserted,
                      let chapterURL = absoluteURL(path, base: baseURL) else { continue }
                let grow = anchor.first { $0.tag == "span" && $0.hasClass("grow") }
                let label = nonBlank(grow?.first { $0.tag == "span" }?.text) ?? nonBlank(grow?.text) ?? anchor.text
                chapters.append(MangaChapter(id: chapterURL.absoluteString, number: lastNumber(label) ?? 0, title: nonBlank(label)))
            }
        }
        return Manga(
            id: mangaID,
            title: HTMLPayloadParser.decodeEntities(title),
            cover: cover,
            overview: metaContent("description", in: html),
            providerID: id,
            chapters: chapters.sorted { $0.number < $1.number }
        )
    }

    func pages(chapterID: String) async throws -> [MangaPage] {
        guard let path = capture(#"(/chapters/[0-9A-Z]+)"#, in: chapterID),
              let url = URL(string: "\(baseURL.absoluteString)\(path)/images?is_prev=False&reading_style=long_strip") else { return [] }
        let document = AnimeHTML.parse(try await MangaHTTP.text(url, headers: ["HX-Request": "true"]))
        let scope = document.first { $0["id"] == "chapter-images" } ?? document
        var seen = Set<String>()
        let urls = scope.elements("img").compactMap { absoluteURL($0["src"], base: baseURL) }
            .filter { $0.scheme?.hasPrefix("http") == true && !$0.path.hasPrefix("/static/") && seen.insert($0.absoluteString).inserted }
            .sorted { pageNumber($0) < pageNumber($1) }
        return urls.enumerated().map { MangaPage(index: $0.offset, imageURL: $0.element, headers: imageHeaders) }
    }

    private func pageNumber(_ url: URL) -> Int {
        capture(#"-(\d+)\.[a-z]+$"#, in: url.absoluteString).flatMap(Int.init) ?? .max
    }
}

// MARK: MangaHere

struct MangaHereMangaProvider: MangaProvider {
    let id = "mangahere"
    let name = "MangaHere"
    let baseURL = URL(string: "https://www.mangahere.cc")!
    let language = "en"
    var logo: URL? { baseURL.appendingPathComponent("favicon.ico") }

    private func get(_ url: URL, referer: URL? = nil) async throws -> String {
        try await MangaHTTP.text(url, headers: ["Referer": (referer ?? baseURL).absoluteString, "Cookie": "isAdult=1"])
    }

    private func parseCards(_ html: String) -> [Manga] {
        var cards = MangaCardList()
        // Parents are weak references, so the document must outlive the walk.
        let document = AnimeHTML.parse(html)
        defer { withExtendedLifetime(document) {} }
        for image in document.all({ $0.tag == "img" && $0["class"].contains("manga-list") && $0["class"].contains("-cover") }) {
            guard let anchor = image.ancestor({ $0.tag == "a" && $0["href"].contains("/manga/") }),
                  let path = capture(#"(/manga/[a-zA-Z0-9_]+/)"#, in: anchor["href"]),
                  let url = absoluteURL(path, base: baseURL) else { continue }
            let title = nonBlank(anchor["title"]) ?? nonBlank(image["alt"])
            cards.add(Manga(
                id: url.absoluteString,
                title: title.map(HTMLPayloadParser.decodeEntities) ?? slugTitle(url),
                cover: imageSource(image, base: baseURL).map(Self.secure),
                providerID: id
            ))
        }
        return cards.items
    }

    /// The covers come as plain http, which App Transport Security blocks.
    private static func secure(_ url: URL) -> URL {
        guard url.scheme == "http", var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.scheme = "https"
        return components.url ?? url
    }

    func home() async throws -> [MangaCategory] {
        let latest = parseCards(try await get(baseURL))
        return latest.isEmpty ? [] : [MangaCategory(name: "Latest Updates", items: latest)]
    }

    func search(_ query: String) async throws -> [Manga] {
        guard let term = nonBlank(query), let url = URL(string: "\(baseURL.absoluteString)/search?title=\(MangaHTTP.encode(term))") else { return [] }
        return parseCards(try await get(url))
    }

    func manga(id mangaID: String) async throws -> Manga {
        guard let url = URL(string: mangaID) else { throw AppError.invalidURL }
        let html = try await get(url)
        let document = AnimeHTML.parse(html)
        let title = nonBlank(document.first { $0.tag == "h1" || $0.hasClass("detail-info-text-title") }?.text)
            ?? slugTitle(url)
        let coverNode = document.first { $0.hasClass("detail-main-cover") }?.first { $0.tag == "img" }
            ?? document.first { $0.tag == "img" && $0.hasClass("detail-info-cover-img") }
        let cover = imageSource(coverNode, base: baseURL) ?? metaContent("og:image", in: html).flatMap(URL.init(string:))
        let overview = nonBlank(document.first { $0.hasClass("fullcontent") }?.text)
            ?? nonBlank(document.first { $0.hasClass("detail-info-right-content") }?.text)
        // Only this title's chapters; the sidebar links other series' chapters too.
        let ownPrefix = capture(#"(/manga/[a-zA-Z0-9_]+/)"#, in: mangaID) ?? "/manga/"
        var seen = Set<String>()
        let chapters = document.elements("a").compactMap { anchor -> MangaChapter? in
            guard let path = capture(#"(/manga/[a-zA-Z0-9_]+/(?:v\w+/)?c[\d.]+/\d+\.html)"#, in: anchor["href"]),
                  path.hasPrefix(ownPrefix),
                  seen.insert(path).inserted,
                  let chapterURL = absoluteURL(path, base: baseURL) else { return nil }
            let label = nonBlank(anchor["title"]) ?? nonBlank(anchor.first { $0.hasClass("title3") }?.text) ?? nonBlank(anchor.text)
            return MangaChapter(
                id: chapterURL.absoluteString,
                number: capture(#"/c([\d.]+)/"#, in: path).flatMap(Double.init) ?? 0,
                title: label.map(HTMLPayloadParser.decodeEntities)
            )
        }.sorted { $0.number < $1.number }
        return Manga(
            id: mangaID,
            title: HTMLPayloadParser.decodeEntities(title),
            cover: cover.map(Self.secure),
            overview: overview,
            providerID: id,
            chapters: chapters
        )
    }

    func pages(chapterID: String) async throws -> [MangaPage] {
        guard let chapterURL = URL(string: chapterID) else { throw AppError.invalidURL }
        let html = try await get(chapterURL)
        guard let chapterKey = capture(#"chapterid\s*=\s*(\d+)"#, in: html),
              let count = capture(#"imagecount\s*=\s*(\d+)"#, in: html).flatMap(Int.init), count > 0 else { return [] }
        let key = capture(#"id="dm5_key"\s+value="([^"]*)""#, in: html) ?? ""
        let directory = chapterURL.deletingLastPathComponent().absoluteString
        // One request per page like Android, six at a time; stops at the first gap.
        var urls: [URL] = []
        var batchStart = 1
        pageLoop: while batchStart <= count {
            let batch = Array(batchStart...min(batchStart + 5, count))
            let resolved = await withTaskGroup(of: (Int, URL?).self) { group -> [Int: URL] in
                for page in batch {
                    group.addTask {
                        guard let requestURL = URL(string: "\(directory)chapterfun.ashx?cid=\(chapterKey)&page=\(page)&key=\(key)"),
                              let raw = try? await get(requestURL, referer: chapterURL) else { return (page, nil) }
                        return (page, Self.pageURL(from: raw))
                    }
                }
                var found: [Int: URL] = [:]
                for await (page, url) in group { if let url { found[page] = url } }
                return found
            }
            for page in batch {
                guard let url = resolved[page] else { break pageLoop }
                urls.append(url)
            }
            batchStart += batch.count
        }
        return urls.enumerated().map { MangaPage(index: $0.offset, imageURL: $0.element, headers: imageHeaders) }
    }

    private static func pageURL(from raw: String) -> URL? {
        guard let script = JSPacker.unpack(raw) else { return nil }
        // Older responses: `d=["//host/a.jpg", ...]`. Current ones build the list
        // in dm5imagefun(): `pix="//host/dir"; pvalue=["/a.jpg", ...]`.
        var first: String?
        if let list = capture(#"\bd\s*=\s*\[([^\]]*)\]"#, in: script) {
            first = capture(#"["']([^"']+)["']"#, in: list)
        }
        if first == nil, let list = capture(#"pvalue\s*=\s*\[([^\]]*)\]"#, in: script),
           let file = capture(#"["']([^"']+)["']"#, in: list) {
            first = file.hasPrefix("/") ? (capture(#"pix\s*=\s*["']([^"']+)["']"#, in: script) ?? "") + file : file
        }
        guard let first else { return nil }
        if first.hasPrefix("http") { return URL(string: first) }
        if first.hasPrefix("//") { return URL(string: "https:" + first) }
        guard first.hasPrefix("/"), var base = capture(#"["']((?:https?:)?//[^'"]+)["']"#, in: script) else { return nil }
        if base.hasPrefix("//") { base = "https:" + base }
        return URL(string: base + first)
    }
}

// MARK: Madara (WordPress manga theme)

struct MadaraMangaProvider: MangaProvider {
    let id: String
    let name: String
    let baseURL: URL
    let language = "en"
    let logo: URL?
    var mangaPath = "/manga"
    var usesCloudflare = false

    private func document(_ url: URL) async throws -> String {
        if usesCloudflare { return try await CloudflareResolver.page(url, referer: baseURL) }
        return try await MangaHTTP.text(url)
    }

    private func parseCards(_ html: String) -> [Manga] {
        var cards = MangaCardList()
        let path = NSRegularExpression.escapedPattern(for: mangaPath)
        let cardNodes = AnimeHTML.parse(html).all {
            $0.hasClass("page-item-detail") || $0.hasClass("c-tabs-item__content") || $0.hasClass("manga")
        }
        for card in cardNodes {
            guard let anchor = card.first({ $0.tag == "a" && $0["href"].contains(mangaPath + "/") }),
                  let match = capture("(" + path + #"/[^"'?#\s/]+)"#, in: anchor["href"]),
                  let url = absoluteURL(match + "/", base: baseURL) else { continue }
            let title = nonBlank(card.first { $0.hasClass("post-title") || $0.hasClass("manga-name") || $0.tag == "h3" || $0.tag == "h4" }?.text)
                ?? nonBlank(anchor["title"])
            cards.add(
                Manga(
                    id: url.absoluteString,
                    title: title.map(HTMLPayloadParser.decodeEntities) ?? slugTitle(url),
                    cover: imageSource(card.first { $0.tag == "img" }, base: baseURL),
                    providerID: id
                ),
                titleIsFallback: title == nil
            )
        }
        return cards.items
    }

    func home() async throws -> [MangaCategory] {
        let latest = parseCards(try await document(baseURL))
        return latest.isEmpty ? [] : [MangaCategory(name: "Latest Updates", items: latest)]
    }

    func search(_ query: String) async throws -> [Manga] {
        guard let term = nonBlank(query),
              let url = URL(string: "\(baseURL.absoluteString)/?s=\(MangaHTTP.encode(term))&post_type=wp-manga") else { return [] }
        return parseCards(try await document(url))
    }

    func manga(id mangaID: String) async throws -> Manga {
        guard let url = URL(string: mangaID) else { throw AppError.invalidURL }
        let html = try await document(url)
        let page = AnimeHTML.parse(html)
        let title = nonBlank(page.first { $0.hasClass("post-title") }?.first { $0.tag == "h1" }?.text)
            ?? nonBlank(page.first { $0.tag == "h1" }?.text)
            ?? slugTitle(url)
        let cover = imageSource(
            page.first { $0.hasClass("summary_image") || $0.hasClass("thumb") }?.first { $0.tag == "img" },
            base: baseURL
        )
        let overview = nonBlank(page.first { $0.hasClass("summary__content") || $0.hasClass("description-summary") || $0.hasClass("summary_content") }?.text)
        let author = nonBlank(page.first { $0.hasClass("author-content") || $0.hasClass("post-author") }?.first { $0.tag == "a" }?.text)
        let status = nonBlank(page.first { $0.hasClass("post-status") }?.all { $0.hasClass("summary-content") }.last?.text)

        var chapters = parseChapters(html)
        if chapters.isEmpty {
            let mangaKey = page.first { $0["id"] == "manga-chapters-holder" }?["data-id"]
                ?? page.first { $0.tag == "input" && $0["name"] == "manga_id" }?["value"]
            if let mangaKey = nonBlank(mangaKey),
               let ajax = try? await MangaHTTP.text(
                   baseURL.appendingPathComponent("wp-admin/admin-ajax.php"),
                   headers: ["X-Requested-With": "XMLHttpRequest", "Referer": mangaID],
                   method: "POST",
                   form: ["action": "manga_get_chapters", "manga": mangaKey]
               ) {
                chapters = parseChapters(ajax)
            }
            if chapters.isEmpty, let ajax = try? await MangaHTTP.text(
                url.appendingPathComponent("ajax/chapters/"),
                headers: ["X-Requested-With": "XMLHttpRequest", "Referer": mangaID],
                method: "POST"
            ) {
                chapters = parseChapters(ajax)
            }
        }
        return Manga(
            id: mangaID,
            title: HTMLPayloadParser.decodeEntities(title),
            cover: cover,
            overview: overview,
            author: author,
            status: status,
            providerID: id,
            chapters: chapters
        )
    }

    private func parseChapters(_ html: String) -> [MangaChapter] {
        let path = NSRegularExpression.escapedPattern(for: mangaPath)
        var seen = Set<String>()
        return AnimeHTML.parse(html).elements("a").compactMap { anchor -> MangaChapter? in
            guard let match = capture("(" + path + #"/[^"'?#\s]*/chapter-[^"'?#\s]+/?)"#, in: anchor["href"]),
                  let chapterURL = absoluteURL(match, base: baseURL),
                  seen.insert(chapterURL.absoluteString).inserted else { return nil }
            let label = nonBlank(anchor.text)
            let number = capture(#"chapter-(\d+(?:[.-]\d+)?)"#, in: match)
                .flatMap { Double($0.replacingOccurrences(of: "-", with: ".")) }
                ?? label.flatMap(lastNumber) ?? 0
            return MangaChapter(id: chapterURL.absoluteString, number: number, title: label.map(HTMLPayloadParser.decodeEntities))
        }.sorted { $0.number < $1.number }
    }

    func pages(chapterID: String) async throws -> [MangaPage] {
        guard let url = URL(string: chapterID) else { throw AppError.invalidURL }
        let page = AnimeHTML.parse(try await document(url))
        var images = page.all { $0.hasClass("reading-content") || $0.hasClass("page-break") }
            .flatMap { $0.elements("img") }
        images += page.all { $0.tag == "img" && $0.hasClass("wp-manga-chapter-img") }
        if images.isEmpty { images = page.elements("img") }
        var seen = Set<String>()
        let urls = images.compactMap { node -> URL? in
            let raw = nonBlank(node["data-src"]) ?? nonBlank(node["src"]) ?? ""
            guard let url = absoluteURL(raw, base: baseURL) else { return nil }
            let text = url.absoluteString
            guard text.hasPrefix("http"), !text.contains("logo"),
                  text.range(of: #"\.(webp|jpe?g|png)(\?|#|$)"#, options: [.regularExpression, .caseInsensitive]) != nil,
                  seen.insert(text).inserted else { return nil }
            return url
        }
        return urls.enumerated().map { MangaPage(index: $0.offset, imageURL: $0.element, headers: imageHeaders) }
    }
}
