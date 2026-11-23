import Foundation
import CryptoKit

/// Shared scraping and hoster-resolution layer for the ported BetterStreamflix
/// catalogue providers. Every provider looks a title up on its own site, walks to
/// the page that lists hoster embeds, and hands those embeds to `HosterResolver`.
///
/// Providers soft-fail: an unreachable site yields no candidates instead of an
/// error, so one dead mirror never stops playback discovery.

// MARK: - Shared HTTP

enum ProviderHTTP {
    static let shared: any HTTPClientProtocol = HTTPClient()
}

/// One hoster embed discovered on a provider page.
struct HosterLink: Sendable {
    let name: String
    let url: URL
    var referer: URL?
    var audioLanguage: String?
    /// A link the provider already resolved to a playable file.
    var isDirect: Bool = false
    var headers: [String: String] = [:]
    var subtitles: [SubtitleSource] = []
    /// Used when the playable file is only reachable through provider-specific
    /// work, such as an authenticated ajax call made at playback time.
    var resolveOverride: (@Sendable () async throws -> PlaybackSource)?

    init(
        name: String,
        url: URL,
        referer: URL? = nil,
        audioLanguage: String? = nil,
        isDirect: Bool = false,
        headers: [String: String] = [:],
        subtitles: [SubtitleSource] = [],
        resolveOverride: (@Sendable () async throws -> PlaybackSource)? = nil
    ) {
        self.name = name
        self.url = url
        self.referer = referer
        self.audioLanguage = audioLanguage
        self.isDirect = isDirect
        self.headers = headers
        self.subtitles = subtitles
        self.resolveOverride = resolveOverride
    }
}

extension PlaybackLookupContext {
    /// Anime and cartoon sites are only worth querying for animated titles.
    var isAnimation: Bool {
        request.media.genres.contains { $0.id == "16" || $0.name.lowercased() == "animation" }
    }

    var seasonNumber: Int { request.episode?.seasonNumber ?? 1 }

    /// The episode number a site that numbers a show continuously expects.
    var continuousEpisodeNumber: Int? {
        guard let episode = request.episode else { return nil }
        return episode.seasonNumber > 1 ? (absoluteEpisodeNumber ?? episode.number) : episode.number
    }
}

// MARK: - Provider base

/// A `PlaybackProvider` that scrapes a website. Conformers only implement
/// `hosterLinks(for:)`; candidate construction, kind filtering, soft-failing and
/// hoster resolution are shared.
protocol ScrapedPlaybackProvider: PlaybackProvider {
    var displayName: String { get }
    /// Audio language reported for candidates that do not specify one.
    var audioLanguage: String { get }
    var baseURL: URL { get }
    var supportsMovies: Bool { get }
    var supportsSeries: Bool { get }
    var client: any HTTPClientProtocol { get }

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink]
}

extension ScrapedPlaybackProvider {
    var client: any HTTPClientProtocol { ProviderHTTP.shared }
    var supportsMovies: Bool { true }
    var supportsSeries: Bool { true }
    var audioLanguage: String { "en" }

    func candidates(for context: PlaybackLookupContext) async throws -> [PlaybackCandidate] {
        switch context.request.media.kind {
        case .movie: guard supportsMovies else { return [] }
        case .series: guard supportsSeries, context.request.episode != nil else { return [] }
        }
        let links: [HosterLink]
        do {
            links = try await hosterLinks(for: context)
        } catch where error.isCancellation {
            throw error
        } catch {
            return []
        }
        let resolver = HosterResolver(client: client)
        var seen: Set<String> = []
        return links.compactMap { link in
            guard seen.insert(link.url.absoluteString).inserted else { return nil }
            let language = link.audioLanguage ?? audioLanguage
            let referer = link.referer ?? baseURL
            return PlaybackCandidate(
                id: "\(id):\(link.url.absoluteString)",
                preference: .init(providerID: id, serverName: link.name, audioLanguage: language),
                providerName: displayName,
                subtitleKind: .unknown,
                resolve: {
                    if let override = link.resolveOverride { return try await override() }
                    if link.isDirect {
                        return PlaybackSource(
                            url: link.url,
                            headers: link.headers.isEmpty
                                ? HosterResolver.headers(for: link.url, referer: referer)
                                : link.headers,
                            subtitles: link.subtitles,
                            preferredPeakBitRate: nil
                        )
                    }
                    let source = try await resolver.resolve(link.url, referer: referer)
                    guard !link.subtitles.isEmpty else { return source }
                    return PlaybackSource(
                        url: source.url,
                        headers: source.headers,
                        subtitles: source.subtitles + link.subtitles,
                        preferredPeakBitRate: source.preferredPeakBitRate
                    )
                }
            )
        }
    }
}

// MARK: - Request helpers

extension ScrapedPlaybackProvider {
    func url(_ path: String, query: [String: String] = [:]) throws -> URL {
        let resolved: URL?
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            resolved = URL(string: path)
        } else {
            resolved = URL(string: path.hasPrefix("/") ? String(path.dropFirst()) : path, relativeTo: baseURL)?.absoluteURL
        }
        guard let resolved, var components = URLComponents(url: resolved, resolvingAgainstBaseURL: true) else {
            throw AppError.invalidURL
        }
        if !query.isEmpty {
            components.queryItems = (components.queryItems ?? []) + query.sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let final = components.url else { throw AppError.invalidURL }
        return final
    }

    func text(
        _ url: URL,
        referer: URL? = nil,
        headers: [String: String] = [:],
        form: [String: String]? = nil,
        body: Data? = nil,
        acceptsJSON: Bool = false
    ) async throws -> String {
        let response = try await ProviderNetwork.data(
            client: client,
            url: url,
            referer: referer ?? baseURL,
            headers: headers,
            form: form,
            body: body,
            acceptsJSON: acceptsJSON
        )
        guard let string = String(data: response.data, encoding: .utf8) else { throw AppError.invalidResponse }
        return string
    }

    func html(
        _ url: URL,
        referer: URL? = nil,
        headers: [String: String] = [:],
        form: [String: String]? = nil
    ) async throws -> AnimeHTML {
        AnimeHTML.parse(try await text(url, referer: referer, headers: headers, form: form))
    }

    func jsonObject(
        _ url: URL,
        referer: URL? = nil,
        headers: [String: String] = [:],
        form: [String: String]? = nil,
        body: Data? = nil
    ) async throws -> [String: Any] {
        let raw = try await text(url, referer: referer, headers: headers, form: form, body: body, acceptsJSON: true)
        guard let value = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
            throw AppError.invalidResponse
        }
        return value
    }

    func jsonArray(
        _ url: URL,
        referer: URL? = nil,
        headers: [String: String] = [:],
        form: [String: String]? = nil
    ) async throws -> [Any] {
        let raw = try await text(url, referer: referer, headers: headers, form: form, acceptsJSON: true)
        guard let value = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [Any] else {
            throw AppError.invalidResponse
        }
        return value
    }

    /// The links a page exposes as hoster embeds: iframes plus the data
    /// attributes the ported sites use to lazy-load players.
    func embedLinks(in tree: AnimeHTML, page: URL, named name: String = "Server") -> [HosterLink] {
        var links: [HosterLink] = []
        let attributes = ["src", "data-src", "data-lazy-src", "data-link", "data-embed", "data-server-embed"]
        for node in tree.all({ $0.tag == "iframe" || !$0["data-link"].isEmpty || !$0["data-embed"].isEmpty }) {
            for attribute in attributes {
                let raw = node[attribute].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty, let resolved = ProviderNetwork.absolute(raw, relativeTo: page) else { continue }
                let label = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
                links.append(HosterLink(
                    name: label.isEmpty ? name : label,
                    url: resolved,
                    referer: page
                ))
                break
            }
        }
        return links
    }
}

enum ProviderNetwork {
    static func data(
        client: any HTTPClientProtocol,
        url: URL,
        referer: URL?,
        headers: [String: String] = [:],
        form: [String: String]? = nil,
        body: Data? = nil,
        acceptsJSON: Bool = false,
        method: String? = nil,
        timeout: TimeInterval = 15
    ) async throws -> HTTPResponse {
        var request = URLRequest.providerRequest(url: url, referer: referer, acceptsJSON: acceptsJSON)
        request.timeoutInterval = timeout
        request.setValue(nil, forHTTPHeaderField: "Cookie")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let form {
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var components = URLComponents()
            components.queryItems = form.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            request.httpBody = components.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B")
                .data(using: .utf8)
        } else if let body {
            request.httpMethod = "POST"
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            request.httpBody = body
        }
        if let method { request.httpMethod = method }
        return try await client.data(for: request)
    }

    static func absolute(_ raw: String, relativeTo base: URL?) -> URL? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        value = value
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "&amp;", with: "&")
        if value.hasPrefix("//") { value = "https:" + value }
        guard let url = base.flatMap({ URL(string: value, relativeTo: $0)?.absoluteURL }) ?? URL(string: value),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host != nil else { return nil }
        return url
    }

    static func slug(_ value: String) -> String {
        AnimeMatching.normalized(value)
            .split(separator: " ")
            .joined(separator: "-")
    }

    static func encoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }
}

// MARK: - Title matching

enum TitleMatch {
    private static let noise: Set<String> = [
        "streaming", "stream", "online", "gratis", "hd", "full", "completo", "complet",
        "ita", "sub", "subita", "subtitulada", "latino", "castellano", "espanol", "audio",
        "vf", "vostfr", "truefrench", "french", "en", "de", "la", "le", "il",
        "altadefinizione", "cb01", "megavideo", "serie", "series", "film", "movie", "pelicula",
        "ver", "lektor", "pl", "napisy", "dubbing", "cda", "vider", "gdrive", "temporada",
        "capitulo", "episodio", "saison", "season", "staffel", "anime", "descargar",
    ]

    static func normalize(_ value: String) -> String {
        AnimeMatching.normalized(
            value
                .replacingOccurrences(of: #"\([^)]*\)"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
        )
    }

    /// The title with site boilerplate removed, e.g. "Dune in streaming ITA HD".
    static func stripped(_ value: String) -> String {
        normalize(value)
            .split(separator: " ")
            .filter { !noise.contains(String($0)) && Int($0) == nil }
            .joined(separator: " ")
    }

    static func year(_ value: String?) -> Int? { AnimeMatching.year(value) }

    static func expectedYear(_ context: PlaybackLookupContext) -> Int? {
        if context.request.media.kind == .series, let seasonYear = context.seasonYear { return seasonYear }
        return year(context.request.media.releaseDate)
    }

    static func matches(
        _ candidate: String,
        year candidateYear: Int? = nil,
        context: PlaybackLookupContext,
        yearTolerance: Int = 1,
        requireYear: Bool = false
    ) -> Bool {
        let wanted = Set(context.titles.flatMap { [normalize($0), stripped($0)] }.filter { !$0.isEmpty })
        guard !wanted.isEmpty else { return false }
        let variants = [normalize(candidate), stripped(candidate)].filter { !$0.isEmpty }
        guard variants.contains(where: { wanted.contains($0) }) else { return false }
        guard let expected = expectedYear(context) else { return !requireYear }
        // When TMDB/IMDb carries a release year, yearless search hits are rejected
        // so franchise remakes cannot steal the original entry.
        guard let candidateYear else { return false }
        // Sites list the local release year, which slips a year against TMDB.
        return abs(candidateYear - expected) <= yearTolerance
    }

    /// Search queries to try, most specific first. Appends the release year so
    /// remakes do not lose to the franchise original in first-hit scrapers.
    static func queries(for context: PlaybackLookupContext, limit: Int = 2) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        let year = expectedYear(context)
        for title in context.titles {
            let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, seen.insert(normalize(cleaned)).inserted else { continue }
            result.append(cleaned)
            if let year {
                let withYear = "\(cleaned) \(year)"
                if seen.insert(normalize(withYear)).inserted {
                    result.append(withYear)
                }
            }
            if result.count >= max(limit * 2, 4) { break }
        }
        return result
    }
}

/// One result row parsed out of a provider's search page.
struct ScrapedResult: Sendable {
    let title: String
    let year: Int?
    let kind: MediaKind?
    let url: URL

    init(title: String, year: Int? = nil, kind: MediaKind? = nil, url: URL) {
        self.title = title
        self.year = year
        self.kind = kind
        self.url = url
    }
}

extension Array where Element == ScrapedResult {
    /// The row that matches the requested title, preferring an exact year match.
    /// Never falls back to title-only when the catalog knows a release year.
    func bestMatch(for context: PlaybackLookupContext) -> ScrapedResult? {
        let kind = context.request.media.kind
        let typed = filter { $0.kind == nil || $0.kind == kind }
        if let exact = typed.first(where: {
            TitleMatch.matches($0.title, year: $0.year, context: context, yearTolerance: 0, requireYear: true)
        }) { return exact }
        if let close = typed.first(where: {
            TitleMatch.matches($0.title, year: $0.year, context: context, requireYear: true)
        }) { return close }
        // Title-only only when TMDB/IMDb has no year, or for series cards that omit year.
        if TitleMatch.expectedYear(context) != nil, context.request.media.kind != .series {
            return nil
        }
        return typed.first { TitleMatch.matches($0.title, context: context) }
    }
}

// MARK: - Hoster resolution

/// Resolves a hoster embed to a playable file. Handles the direct link, the
/// common `sources: [{ file: ... }]` players (plain or P.A.C.K.E.R. packed),
/// DoodStream, VOE, Streamtape and MixDrop, and otherwise follows one iframe.
struct HosterResolver: Sendable {
    let client: any HTTPClientProtocol

    init(client: any HTTPClientProtocol = ProviderHTTP.shared) {
        self.client = client
    }

    func resolve(_ url: URL, referer: URL?, depth: Int = 0) async throws -> PlaybackSource {
        guard depth <= 2, let host = url.host?.lowercased() else { throw AppError.noStream }
        if Self.isDirect(url) {
            return PlaybackSource(
                url: url,
                headers: Self.headers(for: url, referer: referer),
                subtitles: [],
                preferredPeakBitRate: nil
            )
        }
        // Prefer the shared German hoster extractors for DE-style embeds.
        let usesSharedHoster =
            MeinecloudEmbedHelper.isEmbedWrapper(url)
            || host.contains("dood") || host.contains("d000d") || host.contains("dsvplay")
            || host.contains("voe") || host.contains("streamtape") || host.contains("streamta")
            || host.contains("vidoza") || host.contains("vidara") || host.contains("vidsonic")
        if usesSharedHoster, let shared = try? await HosterExtractor.resolve(url, referer: referer) {
            return shared
        }
        if Self.matches(host, ["dood", "d000d", "dsvplay", "vide0.net", "playmogo", "do7go", "myvidplay", "ds2play", "dooood"]) {
            if let source = try? await dood(url) { return source }
        }
        if Self.matches(host, ["voe", "jilliandescribe", "unblockvoe", "maxfinishseveral", "brookethoughi"]) {
            if let source = try? await voe(url) { return source }
        }
        if Self.matches(host, ["streamtape", "streamta.site", "stape", "tapewithadblock"]) {
            if let source = try? await streamtape(url) { return source }
        }
        if Self.matches(host, ["mixdrop", "mxdrop", "dr0pstream", "dropstream", "md3b", "mdbekjwqa"]) {
            if let source = try? await mixdrop(url) { return source }
        }
        if Self.matches(host, ["vixsrc", "vixcloud"]) {
            if let source = try? await VixcloudResolver(client: client).resolve(iframeURL: url, referer: referer ?? url) {
                return source
            }
        }
        // Megacloud/Rabbitstream players already have a native extractor.
        if Self.matches(host, ["megacloud", "rabbitstream", "dokicloud", "rapid-cloud", "megaplay", "vidcloud"])
            || url.path.contains("/embed-") || url.path.contains("/e-") {
            if let source = try? await AnimeStreamResolver(client: client).resolve(url, referer: referer ?? url) {
                return source
            }
        }
        // Dedicated extractors ported for the wider hoster ecosystem
        // (Filemoon, StreamWish, Vidmoly, ...); unmatched hosts fall through.
        if let extended = try? await ExtendedHosterExtractor.resolve(url, referer: referer, depth: depth) {
            return extended
        }
        return try await generic(url, referer: referer, depth: depth)
    }

    // MARK: Generic player pages

    private func generic(_ url: URL, referer: URL?, depth: Int) async throws -> PlaybackSource {
        let page = try await get(url, referer: referer)
        let scripts = Self.scriptBodies(in: page)
        let haystacks = [page] + scripts.compactMap { JSPacker.unpack($0) }
        for haystack in haystacks {
            if let file = Self.findSource(in: haystack), let resolved = ProviderNetwork.absolute(file, relativeTo: url) {
                return PlaybackSource(
                    url: resolved,
                    headers: Self.headers(for: resolved, referer: url),
                    subtitles: Self.subtitles(in: haystack, relativeTo: url),
                    preferredPeakBitRate: nil
                )
            }
        }
        guard depth < 2 else { throw AppError.noStream }
        for haystack in haystacks {
            guard let next = Self.findRedirect(in: haystack) ?? Self.findIframe(in: haystack),
                  let resolved = ProviderNetwork.absolute(next, relativeTo: url),
                  resolved != url else { continue }
            if let source = try? await resolve(resolved, referer: url, depth: depth + 1) { return source }
        }
        throw AppError.noStream
    }

    // MARK: Hoster specifics

    private func dood(_ url: URL) async throws -> PlaybackSource {
        let embed = URL(string: url.absoluteString.replacingOccurrences(of: "/d/", with: "/e/")) ?? url
        let response = try await ProviderNetwork.data(client: client, url: embed, referer: url, timeout: 12)
        guard let page = String(data: response.data, encoding: .utf8) else { throw AppError.invalidResponse }
        let final = response.response.url ?? embed
        guard let host = final.host, let scheme = final.scheme,
              let path = AnimeHTML.captures(#"(/pass_md5/[^'"\s]+)"#, in: page).first?[1],
              let passURL = URL(string: "\(scheme)://\(host)\(path)") else { throw AppError.noStream }
        let prefix = try await text(passURL, referer: final)
        guard prefix.hasPrefix("http") else { throw AppError.noStream }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        let token = String((0..<10).map { _ in alphabet.randomElement() ?? "a" })
        guard let source = URL(string: "\(prefix)\(token)?token=\(passURL.lastPathComponent)") else {
            throw AppError.noStream
        }
        return PlaybackSource(
            url: source,
            headers: ["Referer": "\(scheme)://\(host)/", "User-Agent": HTTPClient.desktopUserAgent],
            subtitles: [],
            preferredPeakBitRate: nil
        )
    }

    private func voe(_ url: URL) async throws -> PlaybackSource {
        var page = try await text(url, referer: url)
        // VOE serves a one-line bounce page on its rotating domains.
        if VoeCrypto.payload(in: page) == nil,
           let redirect = Self.findRedirect(in: page) ?? AnimeHTML.captures(#"['"](https://[a-z0-9.-]+/e/[^'"]+)['"]"#, in: page).first?[1],
           let next = ProviderNetwork.absolute(redirect, relativeTo: url) {
            page = try await text(next, referer: url)
        }
        guard let payload = VoeCrypto.payload(in: page),
              let file = payload["source"] as? String ?? payload["file"] as? String,
              let source = ProviderNetwork.absolute(file, relativeTo: url) else { throw AppError.noStream }
        let base = AnimeHTML.captures(#"var\s+base\s*=\s*['"]([^'"]+)['"]"#, in: page).first?[1] ?? ""
        let subtitles = (payload["captions"] as? [[String: Any]] ?? []).compactMap { caption -> SubtitleSource? in
            guard let raw = caption["file"] as? String else { return nil }
            let absolute = raw.hasPrefix("http") ? raw : base + raw
            guard let subtitleURL = ProviderNetwork.absolute(absolute, relativeTo: url) else { return nil }
            let label = caption["label"] as? String ?? "Subtitle"
            return SubtitleSource(
                providerID: "voe",
                providerName: "VOE",
                label: label,
                languageCode: AnimeStreamResolver.languageCode(label),
                url: subtitleURL
            )
        }
        return PlaybackSource(
            url: source,
            headers: Self.headers(for: source, referer: url),
            subtitles: subtitles,
            preferredPeakBitRate: nil
        )
    }

    private func streamtape(_ url: URL) async throws -> PlaybackSource {
        let page = try await text(url, referer: url)
        let pattern = #"botlink'\)\.innerHTML\s*=\s*'([^']+)'\s*\+\s*\('([^']+)'\)\.substring\((\d+)\)"#
        guard let match = AnimeHTML.captures(pattern, in: page).first,
              let offset = Int(match[3]), match[2].count > offset else { throw AppError.noStream }
        let link = match[1] + String(match[2].dropFirst(offset))
        guard let source = ProviderNetwork.absolute(link.contains("//") ? link : "https:" + link, relativeTo: url),
              var components = URLComponents(url: source, resolvingAgainstBaseURL: false) else { throw AppError.noStream }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "stream", value: "1")]
        guard let final = components.url else { throw AppError.noStream }
        return PlaybackSource(
            url: final,
            headers: Self.headers(for: final, referer: url),
            subtitles: [],
            preferredPeakBitRate: nil
        )
    }

    private func mixdrop(_ url: URL) async throws -> PlaybackSource {
        let embed = URL(string: url.absoluteString.replacingOccurrences(of: "/f/", with: "/e/")) ?? url
        let page = try await text(embed, referer: embed)
        let script = Self.scriptBodies(in: page).compactMap { JSPacker.unpack($0) }.first ?? page
        guard let file = AnimeHTML.captures(#"wurl[^=]*=[^"']*["']([^"']+)["']"#, in: script).first?[1],
              let source = ProviderNetwork.absolute(file, relativeTo: embed) else { throw AppError.noStream }
        return PlaybackSource(
            url: source,
            headers: Self.headers(for: source, referer: embed),
            subtitles: [],
            preferredPeakBitRate: nil
        )
    }

    // MARK: Utilities

    private func get(_ url: URL, referer: URL?) async throws -> String {
        try await text(url, referer: referer)
    }

    private func text(_ url: URL, referer: URL?) async throws -> String {
        let response = try await ProviderNetwork.data(client: client, url: url, referer: referer, timeout: 12)
        guard let string = String(data: response.data, encoding: .utf8) else { throw AppError.invalidResponse }
        return string
    }

    static func isDirect(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        return path.hasSuffix(".m3u8") || path.hasSuffix(".mp4") || path.hasSuffix(".mpd")
            || path.contains("/master.m3u8") || path.contains("/playlist.m3u8")
    }

    static func headers(for url: URL, referer: URL?) -> [String: String] {
        let origin = referer.flatMap { reference -> String? in
            guard let scheme = reference.scheme, let host = reference.host else { return nil }
            return "\(scheme)://\(host)"
        } ?? url.host.map { "https://\($0)" } ?? ""
        var headers = ["User-Agent": HTTPClient.desktopUserAgent]
        if !origin.isEmpty {
            headers["Referer"] = referer?.absoluteString ?? origin + "/"
            headers["Origin"] = origin
        }
        return headers
    }

    static func matches(_ host: String, _ needles: [String]) -> Bool {
        needles.contains { host.contains($0) }
    }

    static func scriptBodies(in html: String) -> [String] {
        AnimeHTML.captures(#"<script[^>]*>([\s\S]*?)</script>"#, in: html).map { $0[1] }
    }

    static func findSource(in text: String) -> String? {
        let normalized = text
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\u0026", with: "&")
            .replacingOccurrences(of: "&amp;", with: "&")
        let patterns = [
            #"(?:file|src|source|hls|videoUrl|url)\s*[:=]\s*["'](https?://[^"']+\.(?:m3u8|mp4)(?:\?[^"']*)?)["']"#,
            #"sources?\s*[:=]\s*\[\s*["'](https?://[^"']+\.(?:m3u8|mp4)(?:\?[^"']*)?)["']"#,
            #"["'](https?://[^"'\s]+\.(?:m3u8|mp4)(?:\?[^"'\s]*)?)["']"#,
        ]
        for pattern in patterns {
            if let match = AnimeHTML.captures(pattern, in: normalized).first(where: { $0[1].hasPrefix("http") }) {
                return match[1]
            }
        }
        return nil
    }

    static func findRedirect(in text: String) -> String? {
        let patterns = [
            #"window\.location(?:\.href)?\.replace\(\s*['"]([^'"]+)['"]\s*\)"#,
            #"window\.location(?:\.href)?\s*=\s*['"]([^'"]+)['"]"#,
            #"location\.replace\(\s*['"]([^'"]+)['"]\s*\)"#,
            #"location\.href\s*=\s*['"]([^'"]+)['"]"#,
            #"<meta[^>]+http-equiv=["']refresh["'][^>]+content=["'][^"']*url=([^"'>]+)["']"#,
        ]
        for pattern in patterns {
            if let match = AnimeHTML.captures(pattern, in: text).first, !match[1].isEmpty { return match[1] }
        }
        return nil
    }

    static func findIframe(in text: String) -> String? {
        AnimeHTML.captures(#"<iframe[^>]+(?:data-)?src=["']([^"']+)["']"#, in: text).first?[1]
    }

    static func subtitles(in text: String, relativeTo base: URL) -> [SubtitleSource] {
        AnimeHTML.captures(
            #"\{[^{}]*?["']file["']\s*:\s*["']([^"']+\.(?:vtt|srt))["'][^{}]*?\}"#,
            in: text.replacingOccurrences(of: "\\/", with: "/")
        ).compactMap { match in
            guard let url = ProviderNetwork.absolute(match[1], relativeTo: base) else { return nil }
            let label = AnimeHTML.captures(#"["']label["']\s*:\s*["']([^"']+)["']"#, in: match[0]).first?[1] ?? "Subtitle"
            return SubtitleSource(
                providerID: "stream",
                providerName: "Built-in",
                label: label,
                languageCode: AnimeStreamResolver.languageCode(label),
                url: url
            )
        }
    }
}

/// VOE's obfuscated player payload: rot13, filler removal, base64, char shift,
/// reversal and one more base64 round before the JSON appears.
enum VoeCrypto {
    static func payload(in html: String) -> [String: Any]? {
        let encoded = AnimeHTML.captures(#"<script\s+type="application/json">([\s\S]*?)</script>"#, in: html)
            .first?[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let encoded, !encoded.isEmpty else { return nil }
        let unquoted = encoded.trimmingCharacters(in: CharacterSet(charactersIn: "[]\"' \n\t"))
        return decrypt(unquoted)
    }

    static func decrypt(_ value: String) -> [String: Any]? {
        let rotated = String(value.map { character -> Character in
            guard let ascii = character.asciiValue else { return character }
            switch ascii {
            case 65...90: return Character(UnicodeScalar((ascii - 65 + 13) % 26 + 65))
            case 97...122: return Character(UnicodeScalar((ascii - 97 + 13) % 26 + 97))
            default: return character
            }
        })
        var cleaned = rotated
        for filler in ["@$", "^^", "~@", "%?", "*~", "!!", "#&", "_"] {
            cleaned = cleaned.replacingOccurrences(of: filler, with: "")
        }
        guard let first = base64(cleaned) else { return nil }
        let shifted = String(first.unicodeScalars.compactMap { scalar -> Character? in
            guard scalar.value >= 3 else { return nil }
            return Character(UnicodeScalar(scalar.value - 3)!)
        })
        guard let decoded = base64(String(shifted.reversed())),
              let object = try? JSONSerialization.jsonObject(with: Data(decoded.utf8)) as? [String: Any] else { return nil }
        return object
    }

    private static func base64(_ value: String) -> String? {
        var padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        padded += String(repeating: "=", count: (4 - padded.count % 4) % 4)
        guard let data = Data(base64Encoded: padded, options: .ignoreUnknownCharacters) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// P.A.C.K.E.R. unpacker (`eval(function(p,a,c,k,e,d){...})`), the wrapper most
/// of these hosters use around their `sources` declaration.
enum JSPacker {
    static func unpack(_ script: String) -> String? {
        guard script.contains("p,a,c,k,e,") else { return nil }
        guard let match = AnimeHTML.captures(
            #"\}\s*\(\s*'(.*)',\s*(\d+),\s*(\d+),\s*'(.*?)'\.split\('\|'\)"#,
            in: script
        ).first else { return nil }
        let payload = match[1].replacingOccurrences(of: "\\'", with: "'")
        guard let radix = Int(match[2]), let count = Int(match[3]) else { return nil }
        let symbols = match[4].components(separatedBy: "|")
        guard symbols.count == count, let words = try? NSRegularExpression(pattern: #"\b\w+\b"#) else { return nil }
        var output = ""
        var cursor = payload.startIndex
        for match in words.matches(in: payload, range: NSRange(payload.startIndex..., in: payload)) {
            guard let range = Range(match.range, in: payload) else { continue }
            output += payload[cursor..<range.lowerBound]
            let word = String(payload[range])
            if let index = unbase(word, radix: radix), index >= 0, index < symbols.count, !symbols[index].isEmpty {
                output += symbols[index]
            } else {
                output += word
            }
            cursor = range.upperBound
        }
        output += payload[cursor...]
        return output
    }

    private static func unbase(_ value: String, radix: Int) -> Int? {
        if radix <= 36 { return Int(value.lowercased(), radix: radix) }
        let alphabet62 = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
        let alphabet95 = " !\"#$%&\\'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"
        let alphabet = Array(radix <= 62 ? String(alphabet62.prefix(radix)) : String(alphabet95.prefix(radix)))
        var result = 0
        for character in value {
            guard let index = alphabet.firstIndex(of: character) else { return nil }
            result = result * radix + index
        }
        return result
    }
}

// MARK: - Registry

// MARK: - Cloudflare generic

/// Broad scraper for reachable-but-challenged sites whose markup differs per
/// target: every page goes through `CloudflareResolver` (plain HTTP first,
/// WebView only on a challenge); detail pages are internal non-asset links and
/// servers are external iframes / `data-*` embed attributes.
struct CfGenericPlaybackProvider: ScrapedPlaybackProvider {
    let id: String
    let displayName: String
    let audioLanguage: String
    let baseURL: URL
    var seriesHints: [String] = ["/series/", "/serie/", "/tv/", "/show/", "/episode/"]
    var supportsMovies: Bool = true

    static let nepu = CfGenericPlaybackProvider(id: "nepu", displayName: "Nepu", audioLanguage: "en", baseURL: URL(string: "https://nepu.cc/")!)
    static let netplayz = CfGenericPlaybackProvider(id: "netplayz", displayName: "Netplayz", audioLanguage: "en", baseURL: URL(string: "https://netplayz.top/")!)
    static let cinemaCity = CfGenericPlaybackProvider(id: "cinemacity", displayName: "CinemaCity", audioLanguage: "en", baseURL: URL(string: "https://cinemacity.cc/")!)
    static let weCima = CfGenericPlaybackProvider(id: "wecima", displayName: "WeCima", audioLanguage: "ar", baseURL: URL(string: "https://wecima.cx/")!)
    static let cartoony = CfGenericPlaybackProvider(id: "cartoony", displayName: "Cartoony", audioLanguage: "ar", baseURL: URL(string: "https://cartoony.net/")!)
    static let egyBest = CfGenericPlaybackProvider(id: "egybest", displayName: "EgyBest", audioLanguage: "ar", baseURL: URL(string: "https://egybest.la/")!)
    static let burningSeries = CfGenericPlaybackProvider(
        id: "burningseries", displayName: "BurningSeries", audioLanguage: "de",
        baseURL: URL(string: "https://burningseries.co/")!,
        seriesHints: ["/serie/", "/series/", "/episode/"], supportsMovies: false
    )

    private static let blockedEmbedMarkers = ["youtube", "google", "facebook", "twitter", "/cdn-cgi/"]
    private static let assetPattern = #"\.(png|jpe?g|webp|gif|svg|ico|woff2?|css|js)(\?.*)?$"#

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        for query in TitleMatch.queries(for: context) {
            try Task.checkCancellation()
            let encoded = ProviderNetwork.encoded(query)
            for path in ["?s=\(encoded)", "search?q=\(encoded)", "search/\(encoded)"] {
                guard let searchURL = URL(string: baseURL.absoluteString + path),
                      let html = try? await CloudflareResolver.page(searchURL, referer: baseURL) else { continue }
                let results = cards(in: html, base: searchURL)
                guard !results.isEmpty else { continue }
                guard let match = results.bestMatch(for: context) else { break }
                var detail = match.url
                if let episode = context.request.episode {
                    let showHTML = try await CloudflareResolver.page(detail, referer: searchURL)
                    guard let page = episodePage(in: showHTML, base: detail, season: episode.seasonNumber, episode: episode.number) else { return [] }
                    detail = page
                }
                let embeds = try await embeds(for: detail)
                return embeds.enumerated().map { index, embed in
                    HosterLink(name: "\(displayName) \(index + 1)", url: embed, referer: detail, audioLanguage: audioLanguage)
                }
            }
        }
        return []
    }

    private func isInternal(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased().replacingOccurrences(of: "www.", with: "")
        let own = (baseURL.host ?? "").lowercased().replacingOccurrences(of: "www.", with: "")
        return host == own || host.hasSuffix(".\(own)")
    }

    private func isAsset(_ raw: String) -> Bool {
        raw.range(of: Self.assetPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func isDetail(_ url: URL) -> Bool {
        guard isInternal(url), !isAsset(url.absoluteString) else { return false }
        let path = url.path.lowercased()
        guard path.count > 1, path.filter({ $0 == "/" }).count >= 2 || !path.hasSuffix("/") else { return false }
        return !["/category", "/genre", "/page/", "/tag", "/search", "/login", "/register", "/cdn-cgi"].contains(where: path.contains)
    }

    private func cards(in html: String, base: URL) -> [ScrapedResult] {
        var seen: Set<String> = []
        var results: [ScrapedResult] = []
        for match in AnimeHTML.captures(#"<a\s([^>]*)>([\s\S]*?)</a>"#, in: html) {
            guard let href = AnimeHTML.captures(#"href=["']([^"']+)["']"#, in: match[1]).first?[1],
                  let url = ProviderNetwork.absolute(HTMLPayloadParser.decodeEntities(href), relativeTo: base),
                  isDetail(url), seen.insert(url.absoluteString).inserted else { continue }
            let titleAttr = AnimeHTML.captures(#"title=["']([^"']+)["']"#, in: match[1]).first?[1]
            let alt = AnimeHTML.captures(#"alt=["']([^"']+)["']"#, in: match[2]).first?[1]
            let text = match[2].replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            let slug = url.lastPathComponent.replacingOccurrences(of: "-", with: " ")
            let title = [titleAttr, alt, text.count < 150 ? text : nil, slug].compactMap { $0 }
                .map { HTMLPayloadParser.decodeEntities($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? ""
            guard !title.isEmpty else { continue }
            let path = url.path.lowercased()
            let kind: MediaKind = seriesHints.contains(where: path.contains) ? .series : .movie
            results.append(ScrapedResult(title: title, year: AnimeMatching.year(title), kind: kind, url: url))
        }
        return results
    }

    private func episodePage(in html: String, base: URL, season: Int, episode: Int) -> URL? {
        let patterns = [
            #"\b\#(season)x\#(episode)\b"#,
            #"s0?\#(season)[-_]?e0?\#(episode)\b"#,
            #"(season|staffel|saison|temporada)[-/_]?\#(season)[-/_].*(episode|folge|episodio|capitulo)[-/_]?\#(episode)\b"#,
        ]
        let hrefs = AnimeHTML.captures(#"href=["']([^"']+)["']"#, in: html).compactMap {
            ProviderNetwork.absolute(HTMLPayloadParser.decodeEntities($0[1]), relativeTo: base)
        }.filter(isInternal)
        for pattern in patterns {
            if let hit = hrefs.first(where: {
                $0.path.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
            }) { return hit }
        }
        if season == 1, let hit = hrefs.first(where: {
            $0.path.range(of: #"(episode|ep)[-_/]?0?\#(episode)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        }) { return hit }
        return nil
    }

    private func embeds(for detail: URL) async throws -> [URL] {
        let html = try await CloudflareResolver.page(detail, referer: baseURL)
        var found = embeds(in: html, base: detail)
        guard found.isEmpty else { return found }
        let watchPages = AnimeHTML.captures(#"href=["']([^"']+)["']"#, in: html).compactMap {
            ProviderNetwork.absolute(HTMLPayloadParser.decodeEntities($0[1]), relativeTo: detail)
        }.filter { url in
            let lower = url.absoluteString.lowercased()
            return isInternal(url) && url != detail && ["/watch", "/play", "/stream"].contains(where: lower.contains)
        }
        var seen: Set<URL> = []
        for page in watchPages where seen.insert(page).inserted {
            guard seen.count <= 3 else { break }
            if let watchHTML = try? await CloudflareResolver.page(page, referer: detail) {
                found = embeds(in: watchHTML, base: page)
                if !found.isEmpty { break }
            }
        }
        return found
    }

    private func embeds(in html: String, base: URL) -> [URL] {
        var seen: Set<String> = []
        let pattern = #"(?:<iframe[^>]*\ssrc|data-url|data-src|data-embed|data-link|data-href)=["'](https?://[^"']+)["']"#
        return AnimeHTML.captures(pattern, in: html).compactMap { match in
            let raw = HTMLPayloadParser.decodeEntities(match[1])
            let lower = raw.lowercased()
            guard !Self.blockedEmbedMarkers.contains(where: lower.contains), !isAsset(raw),
                  let url = URL(string: raw), !isInternal(url), seen.insert(raw).inserted else { return nil }
            return url
        }
    }
}

// MARK: - Vavoo VOD

/// Vavoo's MediaHubMX "source" action: POST the TMDB/IMDb ids plus language
/// and region, get back hoster embed URLs tagged with their audio languages.
struct VavooVodPlaybackProvider: ScrapedPlaybackProvider {
    let id: String
    let displayName: String
    let audioLanguage: String
    let region: String
    var baseURL: URL { URL(string: "https://vavoo.to/")! }

    static let de = VavooVodPlaybackProvider(id: "vavoovod", displayName: "Vavoo VOD", audioLanguage: "de", region: "DE")
    static let en = VavooVodPlaybackProvider(id: "vavoovodEn", displayName: "Vavoo VOD EN", audioLanguage: "en", region: "GB")
    static let it = VavooVodPlaybackProvider(id: "vavoovodIt", displayName: "Vavoo VOD IT", audioLanguage: "it", region: "IT")
    static let es = VavooVodPlaybackProvider(id: "vavoovodEs", displayName: "Vavoo VOD ES", audioLanguage: "es", region: "ES")
    static let fr = VavooVodPlaybackProvider(id: "vavoovodFr", displayName: "Vavoo VOD FR", audioLanguage: "fr", region: "FR")
    static let pl = VavooVodPlaybackProvider(id: "vavoovodPl", displayName: "Vavoo VOD PL", audioLanguage: "pl", region: "PL")

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        let media = context.request.media
        guard let tmdb = media.tmdbID else { return [] }
        var ids: [String: Any] = ["tmdb_id": String(tmdb)]
        if let imdb = media.imdbID, !imdb.isEmpty { ids["imdb_id"] = imdb }
        var payload: [String: Any] = [
            "language": audioLanguage,
            "region": region,
            "clientVersion": "3.0.2",
            "ids": ids,
            "name": media.title,
        ]
        if let release = media.releaseDate, !release.isEmpty { payload["releaseDate"] = release }
        if let episode = context.request.episode {
            payload["type"] = "series"
            payload["episode"] = [
                "ids": [String: Any](),
                "name": "Episode \(episode.number)",
                "season": episode.seasonNumber,
                "episode": episode.number,
            ] as [String: Any]
        } else {
            payload["type"] = "movie"
        }

        let referer = baseURL.appendingPathComponent(context.request.episode == nil ? "movies" : "series")
        var request = URLRequest(url: baseURL.appendingPathComponent("mediahubmx-source.json"))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 20
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("MediaHubMX/2", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(audioLanguage, forHTTPHeaderField: "Accept-Language")
        request.setValue("https://vavoo.to", forHTTPHeaderField: "Origin")
        request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        let response = try await client.data(for: request)
        let json = try JSONSerialization.jsonObject(with: response.data)

        var seen: Set<String> = []
        var links: [HosterLink] = []
        collect(json, allowed: true, label: nil, seen: &seen, into: &links)
        return links
    }

    private func languageAllowed(_ object: [String: Any], inherited: Bool) -> Bool {
        var languages = (object["languages"] as? [String]) ?? []
        for key in ["language", "lang"] { if let value = object[key] as? String { languages.append(value) } }
        let normalized = languages.compactMap { $0.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) }
        return normalized.isEmpty ? inherited : normalized.contains(audioLanguage)
    }

    private func collect(_ value: Any, allowed: Bool, label: String?, seen: inout Set<String>, into links: inout [HosterLink]) {
        if let array = value as? [Any] {
            for item in array { collect(item, allowed: allowed, label: label, seen: &seen, into: &links) }
            return
        }
        guard let object = value as? [String: Any] else { return }
        let allowedHere = languageAllowed(object, inherited: allowed)
        guard allowedHere else { return }
        let name = [object["name"] as? String, object["tag"] as? String].compactMap { $0 }.joined(separator: " ")
        for key in ["url", "src", "link", "stream", "file"] {
            guard let raw = object[key] as? String, raw.lowercased().hasPrefix("http"),
                  let url = URL(string: raw), seen.insert(raw).inserted else { continue }
            let host = url.host?.replacingOccurrences(of: "www.", with: "") ?? "Server"
            links.append(HosterLink(
                name: "Vavoo • \(host)\(name.isEmpty ? "" : " (\(name))")",
                url: url,
                referer: baseURL,
                audioLanguage: audioLanguage
            ))
        }
        for (_, child) in object where child is [Any] || child is [String: Any] {
            collect(child, allowed: allowedHere, label: name, seen: &seen, into: &links)
        }
    }
}

enum InternationalPlaybackProviders {
    static func english() -> [any PlaybackProvider] {
        [
            SflixPlaybackProvider(),
            RidomoviesPlaybackProvider(),
            AnyMoviePlaybackProvider(),
            MkissaPlaybackProvider(),
            LookMovie2PlaybackProvider(),
            AkwamPlaybackProvider(),
            TopcinemaPlaybackProvider(),
            OnlyflixPlaybackProvider(),
            NetPrimePlaybackProvider(),
            MovyPlaybackProvider(),
            Shahid4uPlaybackProvider(),
            CfGenericPlaybackProvider.nepu,
            CfGenericPlaybackProvider.netplayz,
            CfGenericPlaybackProvider.cinemaCity,
            CfGenericPlaybackProvider.weCima,
            CfGenericPlaybackProvider.cartoony,
            CfGenericPlaybackProvider.egyBest,
            VavooVodPlaybackProvider.en,
        ]
    }

    static func italian() -> [any PlaybackProvider] {
        [
            Altadefinizione01PlaybackProvider(),
            GuardaFlixPlaybackProvider(),
            CB01PlaybackProvider(),
            AnimeUnityPlaybackProvider(),
            AnimeSaturnPlaybackProvider(),
            GuardaSeriePlaybackProvider(),
            StreamingItaPlaybackProvider(),
            AnimeWorldPlaybackProvider(),
            AltadefinizioneXPlaybackProvider(),
            VavooVodPlaybackProvider.it,
        ]
    }

    static func spanish() -> [any PlaybackProvider] {
        [
            FanpelisPlaybackProvider(),
            CuevanaEuPlaybackProvider(),
            LatanimePlaybackProvider(),
            DoramasflixPlaybackProvider(),
            CineCalidadPlaybackProvider(),
            SeriesFlixPlaybackProvider(),
            SeriesTurcasPlaybackProvider(),
            FlixLatamPlaybackProvider(),
            LaCartoonsPlaybackProvider(),
            AnimefenixPlaybackProvider(),
            AnimeFlvPlaybackProvider(),
            JKAnimePlaybackProvider(),
            TioAnimePlaybackProvider(),
            AnimeAv1PlaybackProvider(),
            AnimeOnlineNinjaPlaybackProvider(),
            SoloLatinoPlaybackProvider(),
            Cine24hPlaybackProvider(),
            PelisplustoPlaybackProvider(),
            PelisflixHdPlaybackProvider(),
            PoseidonHD2PlaybackProvider(),
            CineHaxPlaybackProvider(),
            VavooVodPlaybackProvider.es,
        ]
    }

    static func french() -> [any PlaybackProvider] {
        [
            WiflixPlaybackProvider(),
            FrenchAnimePlaybackProvider(),
            FrenchStreamPlaybackProvider(),
            FrembedPlaybackProvider(),
            KidrazPlaybackProvider(),
            FrenchMangaPlaybackProvider(),
            UnJourUnFilmPlaybackProvider(),
            AfterDarkPlaybackProvider(),
            VostfreePlaybackProvider(),
            MiawPlaybackProvider(),
            VavooVodPlaybackProvider.fr,
        ]
    }

    static func polish() -> [any PlaybackProvider] {
        [
            FilmyOnlineCcPlaybackProvider(),
            ZaluknijPlaybackProvider(),
            VavooVodPlaybackProvider.pl,
        ]
    }

    static func all() -> [any PlaybackProvider] {
        english() + italian() + spanish() + french() + polish()
    }
}
