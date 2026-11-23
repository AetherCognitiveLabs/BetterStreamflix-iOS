import Foundation
import CryptoKit

/// English-language BetterStreamflix providers ported from the Android catalogue.

// MARK: - SFlix

/// Rabbitstream-style catalogue: search page → ajax server list → ajax source link.
struct SflixPlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "sflix" }
    var displayName: String { "SFlix" }
    var baseURL: URL { URL(string: "https://sflix.to/")! }

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        for query in TitleMatch.queries(for: context) {
            let slug = query.replacingOccurrences(of: " ", with: "-")
            let search = try await html(url("search/\(ProviderNetwork.encoded(slug))"))
            let results = search.all { $0.hasClass("flw-item") }.compactMap { item -> ScrapedResult? in
                guard let href = item.first({ $0.tag == "a" && !$0["href"].isEmpty })?["href"],
                      let page = ProviderNetwork.absolute(href, relativeTo: baseURL) else { return nil }
                let title = item.first { $0.hasClass("film-name") }?.text ?? ""
                let details = item.all { $0.tag == "span" }.map(\.text)
                let year = details.compactMap { Int($0) }.first { (1900...2100).contains($0) }
                return ScrapedResult(
                    title: title,
                    year: year,
                    kind: href.contains("/movie/") ? .movie : .series,
                    url: page
                )
            }
            guard let match = results.bestMatch(for: context),
                  let numericID = match.url.lastPathComponent.components(separatedBy: "-").last else { continue }

            let serverID: String
            switch context.request.media.kind {
            case .movie:
                serverID = numericID
            case .series:
                guard let episode = context.request.episode else { return [] }
                let seasons = try await html(url("ajax/season/list/\(numericID)"))
                    .all { $0.tag == "a" && !$0["data-id"].isEmpty }
                guard episode.seasonNumber >= 1, seasons.count >= episode.seasonNumber else { continue }
                let seasonID = seasons[episode.seasonNumber - 1]["data-id"]
                let episodes = try await html(url("ajax/season/episodes/\(seasonID)"))
                    .all { $0.hasClass("eps-item") && !$0["data-id"].isEmpty }
                guard let match = episodes.first(where: { node in
                    let label = node.first { $0.hasClass("episode-number") }?.text ?? ""
                    return AnimeHTML.captures(#"Episode\s+(\d+)"#, in: label).first.flatMap { Int($0[1]) } == episode.number
                }) else { continue }
                serverID = match["data-id"]
            }

            let servers = try await html(
                url(context.request.media.kind == .movie
                    ? "ajax/episode/list/\(serverID)"
                    : "ajax/episode/servers/\(serverID)")
            )
            let links = servers.all { $0.tag == "a" && !$0["data-id"].isEmpty }.compactMap { node -> HosterLink? in
                let name = node.first { $0.tag == "span" }?.text ?? node.text
                guard let sourceURL = try? url("ajax/episode/sources/\(node["data-id"])") else { return nil }
                let client = client
                let base = baseURL
                return HosterLink(
                    name: name.isEmpty ? "SFlix" : name,
                    url: sourceURL,
                    referer: base,
                    resolveOverride: {
                        let response = try await ProviderNetwork.data(
                            client: client, url: sourceURL, referer: base, acceptsJSON: true
                        )
                        guard let payload = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
                              let link = payload["link"] as? String,
                              let embed = ProviderNetwork.absolute(link, relativeTo: base) else { throw AppError.noStream }
                        return try await HosterResolver(client: client).resolve(embed, referer: base)
                    }
                )
            }
            if !links.isEmpty { return links }
        }
        return []
    }
}

// MARK: - Ridomovies

/// JSON search API plus a detail page whose players live in `data-embed`.
struct RidomoviesPlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "ridomovies" }
    var displayName: String { "Ridomovies" }
    var baseURL: URL { URL(string: "https://ridomovies.su/")! }

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        for query in TitleMatch.queries(for: context) {
            let payload = try await jsonObject(url("api/search", query: [
                "q": query, "page": "1", "lang": "en", "limit": "20",
            ]))
            let rows = (payload["data"] as? [[String: Any]]) ?? []
            let results = rows.compactMap { row -> (ScrapedResult, String)? in
                guard let slug = row["slug"] as? String ?? row["slugEn"] as? String,
                      let title = row["title"] as? String else { return nil }
                let type = row["type"] as? String
                let kind: MediaKind? = type == "movie" ? .movie : type == "tv" ? .series : nil
                let year = TitleMatch.year(row["releaseDate"] as? String)
                guard let page = try? url(kind == .series ? "tv/\(slug)" : "movie/\(slug)") else { return nil }
                return (ScrapedResult(title: title, year: year, kind: kind, url: page), slug)
            }
            guard let match = results.map(\.0).bestMatch(for: context),
                  let slug = results.first(where: { $0.0.url == match.url })?.1 else { continue }

            let page: URL
            switch context.request.media.kind {
            case .movie:
                page = try url("movie/\(slug)")
            case .series:
                guard let episode = context.request.episode else { return [] }
                page = try url("tv/\(slug)/season-\(episode.seasonNumber)/episode-\(episode.number)")
            }
            let document = try await html(page)
            var links: [HosterLink] = []
            for node in document.all({ !$0["data-embed"].isEmpty || !$0["data-server-embed"].isEmpty }) {
                let raw = node["data-server-embed"].isEmpty ? node["data-embed"] : node["data-server-embed"]
                guard let embed = Self.embedURL(raw, relativeTo: page) else { continue }
                let label = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
                links.append(HosterLink(
                    name: label.isEmpty ? "Ridomovies" : label,
                    url: embed,
                    referer: page
                ))
            }
            if links.isEmpty { links = embedLinks(in: document, page: page, named: "Ridomovies") }
            if !links.isEmpty { return links }
        }
        return []
    }

    /// `data-embed` holds either a bare URL or an escaped iframe snippet.
    private static func embedURL(_ raw: String, relativeTo base: URL) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("http") || trimmed.hasPrefix("//") {
            return ProviderNetwork.absolute(trimmed, relativeTo: base)
        }
        guard let source = HosterResolver.findIframe(in: trimmed) else { return nil }
        return ProviderNetwork.absolute(source, relativeTo: base)
    }
}

// MARK: - AnyMovie

/// WordPress catalogue where each player option pairs an `aside.options` entry
/// with a numbered `div.player div.fgN` iframe.
struct AnyMoviePlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "anymovie" }
    var displayName: String { "AnyMovie" }
    var baseURL: URL { URL(string: "https://anymovie.cc/")! }

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        for query in TitleMatch.queries(for: context) {
            let search = try await html(url("", query: ["s": query]))
            let results = search.all { $0.tag == "article" }.compactMap { article -> ScrapedResult? in
                guard let href = article.all({ $0.tag == "a" && !$0["href"].isEmpty })
                    .first(where: { $0["href"].contains("/movies/") || $0["href"].contains("/series/") })?["href"],
                    let page = ProviderNetwork.absolute(href, relativeTo: baseURL) else { return nil }
                let title = article.first { $0.hasClass("entry-title") }?.text ?? ""
                let year = TitleMatch.year(article.first { $0.hasClass("year") }?.text)
                return ScrapedResult(
                    title: title,
                    year: year,
                    kind: href.contains("/series/") ? .series : .movie,
                    url: page
                )
            }
            guard let match = results.bestMatch(for: context) else { continue }

            let page: URL
            switch context.request.media.kind {
            case .movie:
                page = match.url
            case .series:
                guard let episode = context.request.episode else { return [] }
                let show = try await html(match.url)
                let seasons = show.all { $0.hasClass("seasons-bx") }
                guard episode.seasonNumber >= 1, seasons.count >= episode.seasonNumber else { continue }
                let rows = seasons[episode.seasonNumber - 1].all { $0.tag == "li" }
                guard let row = rows.first(where: { node in
                    let label = node.first { $0.hasClass("title") }?.text ?? ""
                    return AnimeHTML.captures(#"E(\d+)"#, in: label).first.flatMap { Int($0[1]) } == episode.number
                }), let href = row.first({ $0.tag == "a" && !$0["href"].isEmpty })?["href"],
                    let episodeURL = ProviderNetwork.absolute(href, relativeTo: baseURL) else { continue }
                page = episodeURL
            }

            let document = try await html(page)
            let options = document.all { $0.tag == "li" && !$0["data-id"].isEmpty }
            var links: [HosterLink] = []
            for (index, option) in options.enumerated() {
                guard let frame = document.first({ $0.hasClass("fg\(index + 1)") })?
                    .first({ $0.tag == "iframe" && !$0["src"].isEmpty }),
                    let embed = ProviderNetwork.absolute(frame["src"], relativeTo: page) else { continue }
                let name = option.first { $0.hasClass("option") }?.text ?? "Server \(index + 1)"
                if embed.absoluteString.contains("trembed") {
                    let client = client
                    links.append(HosterLink(name: name, url: embed, referer: page, resolveOverride: {
                        let wrapper = try await ProviderNetwork.data(client: client, url: embed, referer: page)
                        guard let body = String(data: wrapper.data, encoding: .utf8),
                              let inner = HosterResolver.findIframe(in: body),
                              let target = ProviderNetwork.absolute(inner, relativeTo: embed) else { throw AppError.noStream }
                        return try await HosterResolver(client: client).resolve(target, referer: embed)
                    }))
                } else {
                    links.append(HosterLink(name: name, url: embed, referer: page))
                }
            }
            if links.isEmpty { links = embedLinks(in: document, page: page, named: "AnyMovie") }
            if !links.isEmpty { return links }
        }
        return []
    }
}

// MARK: - MKissa

/// AllAnime-style GraphQL API. Episode sources sit behind the `aa-crypto`
/// handshake: derive the build mask, bootstrap a lane key, then sign the query.
struct MkissaPlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "mkissa" }
    var displayName: String { "MKissa" }
    var baseURL: URL { URL(string: "https://api.mkissa.net/")! }
    var audioLanguage: String { "ja" }

    private static let searchHash = "a24c500a1b765c68ae1d8dd85174931f661c71369c89b92b88b75a725afc471c"
    private static let sourceHash = "d405d0edd690624b66baba3068e0edc3ac90f1597d898a1ec8db4e5c43c00fec"
    private static let clockURL = "https://allanime.day"
    private static let siteHeaders = [
        "Origin": "https://mkissa.to",
        "Referer": "https://mkissa.to/",
        "x-build-id": MkissaCrypto.buildID,
    ]

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        guard context.isAnimation else { return [] }
        let wantsMovie = context.request.media.kind == .movie
        let episodeString = wantsMovie ? "1" : String(context.continuousEpisodeNumber ?? 1)

        for query in TitleMatch.queries(for: context) {
            var showID: String?
            for translation in ["sub", "dub"] where showID == nil {
                let variables: [String: Any] = [
                    "search": ["query": query],
                    "limit": 26,
                    "page": 1,
                    "translationType": translation,
                    "allowAdult": false,
                ]
                let response = try await api(variables: variables, hash: Self.searchHash, signed: false)
                let edges = ((response["data"] as? [String: Any])?["shows"] as? [String: Any])?["edges"] as? [[String: Any]]
                showID = (edges ?? []).first { show in
                    let type = (show["type"] as? String ?? "").lowercased()
                    guard wantsMovie == (type == "movie") else { return false }
                    let names = [show["name"], show["englishName"], show["nativeName"], show["nameOnlyString"]]
                        .compactMap { $0 as? String } + (show["altNames"] as? [String] ?? [])
                    let year = (show["airedStart"] as? [String: Any])?["year"] as? Int
                    return names.contains { TitleMatch.matches($0, year: year, context: context) }
                }?["_id"] as? String
            }
            guard let showID else { continue }

            var links: [HosterLink] = []
            for translation in ["sub", "dub"] {
                let variables: [String: Any] = [
                    "showId": showID,
                    "translationType": translation,
                    "episodeString": episodeString,
                ]
                guard let response = try? await api(variables: variables, hash: Self.sourceHash, signed: true) else { continue }
                let episode = (response["data"] as? [String: Any])?["episode"] as? [String: Any]
                let sources = episode?["sourceUrls"] as? [[String: Any]] ?? []
                for source in sources {
                    let raw = (source["sourceUrl"] as? String) ?? (source["url"] as? String) ?? ""
                    guard let resolved = Self.decodeSourceURL(raw) else { continue }
                    let name = (source["sourceName"] as? String ?? "MKissa") + " " + translation.uppercased()
                    if resolved.hasPrefix("/apivtwo/") {
                        let client = client
                        guard let clock = URL(string: Self.clockURL + resolved
                            .replacingOccurrences(of: "/apivtwo/clock?", with: "/apivtwo/clock.json?")) else { continue }
                        links.append(HosterLink(
                            name: name,
                            url: clock,
                            audioLanguage: translation == "dub" ? "en" : "ja",
                            resolveOverride: {
                                let response = try await ProviderNetwork.data(
                                    client: client, url: clock, referer: URL(string: Self.clockURL + "/player.html"),
                                    headers: ["Origin": Self.clockURL], acceptsJSON: true
                                )
                                guard let payload = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
                                      let entries = payload["links"] as? [[String: Any]] else { throw AppError.noStream }
                                let file = entries.compactMap { entry in
                                    (entry["link"] ?? entry["url"] ?? entry["sourceUrl"] ?? entry["file"]) as? String
                                }.first
                                guard let file, let stream = ProviderNetwork.absolute(file, relativeTo: clock) else {
                                    throw AppError.noStream
                                }
                                if HosterResolver.isDirect(stream) {
                                    return PlaybackSource(
                                        url: stream,
                                        headers: [
                                            "Origin": Self.clockURL,
                                            "Referer": Self.clockURL + "/",
                                            "User-Agent": HTTPClient.desktopUserAgent,
                                        ],
                                        subtitles: [],
                                        preferredPeakBitRate: nil
                                    )
                                }
                                return try await HosterResolver(client: client).resolve(stream, referer: clock)
                            }
                        ))
                    } else if let embed = ProviderNetwork.absolute(resolved, relativeTo: baseURL) {
                        links.append(HosterLink(
                            name: name,
                            url: embed,
                            audioLanguage: translation == "dub" ? "en" : "ja"
                        ))
                    }
                }
            }
            if !links.isEmpty { return links }
        }
        return []
    }

    private func api(variables: [String: Any], hash: String, signed: Bool) async throws -> [String: Any] {
        var extensions: [String: Any] = ["persistedQuery": ["version": 1, "sha256Hash": hash]]
        if signed {
            guard let material = try? await MkissaCrypto.material(client: client) else { throw AppError.noStream }
            extensions["k"] = MkissaCrypto.lane
            extensions["aaReq"] = MkissaCrypto.request(key: material.key, epoch: material.epoch, queryHash: hash)
        }
        let endpoint = try url("api", query: [
            "variables": Self.encode(variables),
            "extensions": Self.encode(extensions),
        ])
        return try await jsonObject(endpoint, referer: URL(string: "https://mkissa.to/"), headers: Self.siteHeaders)
    }

    private static func encode(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }

    /// Source URLs arrive as `--` followed by hex bytes XOR-ed with 56.
    static func decodeSourceURL(_ value: String) -> String? {
        guard !value.isEmpty else { return nil }
        guard value.hasPrefix("--") else { return value }
        let hex = Array(value.dropFirst(2))
        guard hex.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        for index in stride(from: 0, to: hex.count, by: 2) {
            guard let byte = UInt8(String(hex[index...index + 1]), radix: 16) else { return nil }
            bytes.append(byte ^ 56)
        }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// AllAnime/MKissa client crypto. The mask comes from the shipped build seeds,
/// the lane key from a bootstrap call, and each protected query carries an
/// AES-GCM request token.
enum MkissaCrypto {
    static let lane = "k7"
    static let buildID = "166"

    private static let keyGroup = "mkissa"
    private static let refererHost = "mkissa.to"
    private static let bootPrefix = "ld1faaOf3G:"
    private static let seeds = ["0VmOiOTlfQ0=", "F/SlaG5999I=", "VTm6fMS7BdQ=", "LIQNr2OipeQ="]
    private static let saltMultiplier = 165
    private static let saltAddend = 115
    private static let fragmentMultiplier = 197
    private static let fragmentAddend = 200
    private static let keySize = 16 * 2
    private static let epochMilliseconds = 7 * 24 * 60 * 60 * 1000
    private static let graceMilliseconds = 24 * 60 * 60 * 1000
    private static let requestWindowMilliseconds = 5 * 60 * 1000

    struct Material: Sendable {
        let epoch: Int
        let key: Data
    }

    private actor Cache {
        private var material: Material?
        private var expiry = 0

        func value(now: Int) -> Material? {
            guard let material, now < expiry else { return nil }
            return material
        }

        func store(_ value: Material, expiry: Int) {
            material = value
            self.expiry = expiry
        }
    }

    private static let cache = Cache()

    static func material(client: any HTTPClientProtocol) async throws -> Material {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        if let cached = await cache.value(now: now) { return cached }
        guard let mask = mask() else { throw AppError.noStream }
        for epoch in epochCandidates(now: now) {
            guard let endpoint = URL(string: "https://api.mkissa.net/client-crypto/v1/bootstrap?buildId=\(buildID)&k=\(lane)") else {
                continue
            }
            let response = try? await ProviderNetwork.data(
                client: client,
                url: endpoint,
                referer: URL(string: "https://mkissa.to/"),
                headers: [
                    "Origin": "https://mkissa.to",
                    "x-build-id": buildID,
                    "x-aa-boot": bootToken(mask: mask, epoch: epoch),
                ],
                acceptsJSON: true
            )
            guard let response,
                  let payload = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
                  let partB = (payload["partB"] as? String).flatMap({ Data(base64Encoded: $0) }),
                  partB.count >= keySize else { continue }
            let material = Material(epoch: (payload["epoch"] as? Int) ?? epoch, key: key(mask: mask, partB: partB))
            let switchAt = (payload["switchAt"] as? Int) ?? (now + epochMilliseconds)
            await cache.store(material, expiry: min(switchAt, now + epochMilliseconds))
            return material
        }
        throw AppError.noStream
    }

    static func request(key: Data, epoch: Int, queryHash: String) -> String {
        let timestamp = Int(Date().timeIntervalSince1970 * 1000) / requestWindowMilliseconds * requestWindowMilliseconds
        let seed = "\(epoch):\(buildID):\(queryHash):\(timestamp):\(lane)"
        let nonce = Data(SHA256.hash(data: Data(seed.utf8)).prefix(12))
        let payload: [String: Any] = [
            "v": 1, "ts": timestamp, "epoch": epoch, "buildId": buildID, "qh": queryHash, "k": lane,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload),
              let box = try? AES.GCM.seal(
                  body,
                  using: SymmetricKey(data: key),
                  nonce: try AES.GCM.Nonce(data: nonce)
              ) else { return "" }
        return (Data([1]) + nonce + box.ciphertext + box.tag).base64EncodedString()
    }

    private static func epochCandidates(now: Int) -> [Int] {
        let current = now / epochMilliseconds
        let inGrace = now - current * epochMilliseconds < graceMilliseconds && current > 0
        return inGrace ? [current - 1, current] : [current]
    }

    private static func mask() -> Data? {
        let identifier = Array(buildID.utf8)
        guard !identifier.isEmpty else { return nil }
        let stream = (0..<keySize).map { index in
            identifier[index % identifier.count] ^ UInt8((index * saltMultiplier + saltAddend) & 0xFF)
        }
        var mask = [UInt8](repeating: 0, count: keySize)
        let fragment = keySize / seeds.count
        for (index, seed) in seeds.enumerated() {
            guard let bytes = Data(base64Encoded: seed), bytes.count >= fragment else { return nil }
            for offset in 0..<fragment {
                mask[index * fragment + offset] = bytes[offset]
                    ^ stream[index * fragment + offset]
                    ^ UInt8((index * fragmentMultiplier + offset * fragmentAddend) & 0xFF)
            }
        }
        return mask.allSatisfy { $0 == 0 } ? nil : Data(mask)
    }

    private static func key(mask: Data, partB: Data) -> Data {
        Data((0..<keySize).map { partB[$0] ^ mask[$0 % mask.count] })
    }

    private static func bootToken(mask: Data, epoch: Int) -> String {
        let inner = HMAC<SHA256>.authenticationCode(
            for: Data("\(bootPrefix)\(buildID)".utf8),
            using: SymmetricKey(data: mask)
        )
        let message = [keyGroup, lane, String(epoch), refererHost, buildID].joined(separator: ":")
        let token = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data(inner)))
        return Data(token).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - LookMovie2

/// Server-rendered catalog. Play pages embed `window['movie_storage']`
/// (`id_movie`, `hash`, `expires`) that unlocks direct HLS per quality from
/// `/api/v1/security/movie-access`. Series tokens live in client state only,
/// so only movies are exposed.
struct LookMovie2PlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "lookmovie2" }
    var displayName: String { "LookMovie2" }
    var baseURL: URL { URL(string: "https://www.lookmovie2.to/")! }
    var supportsSeries: Bool { false }

    private static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        guard context.request.media.kind == .movie else { return [] }
        let headers = ["User-Agent": Self.userAgent]
        for query in TitleMatch.queries(for: context) {
            let search = try url("movies/search/", query: ["q": query, "page": "1"])
            guard let page = try? await html(search, headers: headers) else { continue }
            var seen = Set<String>()
            let results: [ScrapedResult] = page.all { $0.tag == "a" && $0["href"].contains("/movies/view/") }.compactMap { anchor in
                guard let link = try? url(anchor["href"]), seen.insert(link.absoluteString).inserted else { return nil }
                let slug = link.lastPathComponent
                let title = anchor.first { $0.tag == "img" }?["alt"] ?? anchor.text
                let year = AnimeHTML.captures(#"-(\d{4})$"#, in: slug).first.flatMap { Int($0[1]) }
                return ScrapedResult(title: title.trimmingCharacters(in: .whitespacesAndNewlines), year: year, kind: .movie, url: link)
            }
            guard let match = results.bestMatch(for: context) else { continue }
            let playURL = URL(string: match.url.absoluteString.replacingOccurrences(of: "/movies/view/", with: "/movies/play/"))!
            let access = try await streams(playURL: playURL, detail: match.url)
            return access.streams.map { quality, stream in
                HosterLink(
                    name: "LookMovie \(quality)",
                    url: stream,
                    referer: match.url,
                    isDirect: true,
                    headers: ["User-Agent": Self.userAgent, "Referer": match.url.absoluteString],
                    subtitles: access.subtitles
                )
            }
        }
        return []
    }

    private func streams(playURL: URL, detail: URL) async throws -> (streams: [(String, URL)], subtitles: [SubtitleSource]) {
        let headers = ["User-Agent": Self.userAgent]
        let page = try await text(playURL, referer: detail, headers: headers)
        guard let storage = AnimeHTML.captures(#"window\['movie_storage'\]\s*=\s*\{([\s\S]*?)\};"#, in: page).first?[1],
              let movieID = AnimeHTML.captures(#"id_movie:\s*(\d+)"#, in: storage).first?[1],
              let hash = AnimeHTML.captures(#"hash:\s*"([^"]+)""#, in: storage).first?[1],
              let expires = AnimeHTML.captures(#"expires:\s*(\d+)"#, in: storage).first?[1]
        else { return ([], []) }
        let api = try url("api/v1/security/movie-access", query: [
            "id_movie": movieID, "hash": hash, "expires": expires, "step": "1",
        ])
        let root = try await jsonObject(api, referer: playURL, headers: headers)
        guard root["success"] as? Bool == true else { return ([], []) }
        let streams = (root["streams"] as? [String: Any] ?? [:])
            .compactMap { quality, value -> (String, URL)? in
                guard let raw = value as? String, let url = URL(string: raw) else { return nil }
                return (quality, url)
            }
            .sorted { (Int($0.0.filter(\.isNumber)) ?? 0) > (Int($1.0.filter(\.isNumber)) ?? 0) }
        let subtitles: [SubtitleSource] = (root["subtitles"] as? [[String: Any]] ?? []).compactMap { entry in
            let raw = (entry["file"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (entry["src"] as? String ?? "")
            guard !raw.isEmpty, let file = try? url(raw) else { return nil }
            let label = (entry["language"] as? String) ?? (entry["label"] as? String) ?? "English"
            return SubtitleSource(
                providerID: id,
                providerName: displayName,
                label: label,
                languageCode: AnimeStreamResolver.languageCode(label),
                url: file
            )
        }
        return (streams, subtitles)
    }
}

// MARK: - Akwam

/// Arabic catalog. Movie and episode pages list per-quality
/// `/download/{file}/{content}/{slug}` pages whose body links the direct MP4
/// on downet.net, so no hoster extractor is involved.
struct AkwamPlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "akwam" }
    var displayName: String { "Akwam" }
    var baseURL: URL { URL(string: "https://akwam.ss/")! }
    var audioLanguage: String { "ar" }

    private static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        let headers = ["User-Agent": Self.userAgent]
        let isSeries = context.request.media.kind == .series
        let section = isSeries ? "/series/" : "/movie/"
        for query in TitleMatch.queries(for: context) {
            let search = try url("search", query: ["q": query])
            guard let page = try? await html(search, headers: headers) else { continue }
            let results: [ScrapedResult] = page.all { $0.hasClass("entry-box") }.compactMap { box in
                guard let anchor = box.first({ $0.tag == "a" && $0["href"].contains(section) }),
                      let link = try? url(anchor["href"]) else { return nil }
                let title = box.first { $0.hasClass("entry-title") }?.text ?? anchor["title"]
                let year = AnimeHTML.captures(#"\b((?:19|20)\d{2})\b"#, in: box.text).first.flatMap { Int($0[1]) }
                return ScrapedResult(
                    title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                    year: year,
                    kind: isSeries ? .series : .movie,
                    url: link
                )
            }
            guard let match = results.bestMatch(for: context) else { continue }
            var target = match.url
            if isSeries {
                guard let episode = context.request.episode,
                      let show = try? await html(match.url, headers: headers),
                      let found = Self.episodeURL(in: show, number: episode.number, resolve: { try? url($0) }) else { continue }
                target = found
            }
            let detail = try await html(target, headers: headers)
            return downloadLinks(in: detail, page: target)
        }
        return []
    }

    private func downloadLinks(in page: AnimeHTML, page pageURL: URL) -> [HosterLink] {
        var seen = Set<String>()
        let anchors = page.all { $0.tag == "a" && $0["href"].contains("/download/") }
        return anchors.enumerated().compactMap { index, anchor in
            guard let download = try? url(anchor["href"]), seen.insert(download.absoluteString).inserted else { return nil }
            let provider = self
            return HosterLink(
                name: "Akwam \(index + 1)",
                url: download,
                referer: pageURL,
                isDirect: true,
                headers: ["User-Agent": Self.userAgent, "Referer": download.absoluteString],
                resolveOverride: {
                    let body = try await provider.text(download, referer: pageURL, headers: ["User-Agent": Self.userAgent])
                    guard let raw = AnimeHTML.captures(#"https?://[^"'\s<>]+\.(?:mp4|mkv)"#, in: body).first?[0],
                          let file = URL(string: raw) else { throw AppError.invalidResponse }
                    return PlaybackSource(
                        url: file,
                        headers: ["User-Agent": Self.userAgent, "Referer": download.absoluteString],
                        subtitles: [],
                        preferredPeakBitRate: nil
                    )
                }
            )
        }
    }

    private static func episodeURL(in page: AnimeHTML, number: Int, resolve: (String) -> URL?) -> URL? {
        let anchors = page.all { $0.tag == "a" && $0["href"].contains("/episode/") }
        var ordered: [URL] = []
        for anchor in anchors {
            guard let link = resolve(anchor["href"]), !ordered.contains(link) else { continue }
            let decoded = link.absoluteString.removingPercentEncoding ?? link.absoluteString
            if let match = AnimeHTML.captures(#"الحلقة-(\d+)"#, in: decoded).first, Int(match[1]) == number {
                return link
            }
            ordered.append(link)
        }
        return nil
    }
}

// MARK: - TopCinema

/// Arabic WordPress catalog. Each movie's `/watch/` page lists
/// `li.server--item[data-id][data-server]`; POSTing those to the theme's
/// `Ajaxat/Single/Server.php` returns the hoster iframe. Series `/watch/`
/// links redirect to episode lists, so only movies are exposed.
struct TopcinemaPlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "topcinema" }
    var displayName: String { "TopCinema" }
    var baseURL: URL { URL(string: "https://topcinemaa.one/")! }
    var audioLanguage: String { "en" }
    var supportsSeries: Bool { false }

    private static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        guard context.request.media.kind == .movie else { return [] }
        let headers = ["User-Agent": Self.userAgent]
        for query in TitleMatch.queries(for: context) {
            guard let page = try? await html(try url("", query: ["s": query]), headers: headers) else { continue }
            let results: [ScrapedResult] = page.all { $0.hasClass("Small--Box") }.compactMap { box in
                guard let anchor = box.first({ $0.tag == "a" && !$0["href"].isEmpty }),
                      let link = try? url(anchor["href"]) else { return nil }
                let raw = anchor["title"].isEmpty ? (box.first { $0.tag == "h3" }?.text ?? "") : anchor["title"]
                guard !raw.hasPrefix("مسلسل") else { return nil }
                return Self.result(from: raw, url: link)
            }
            guard let match = results.bestMatch(for: context) else { continue }
            let watch = match.url.appendingPathComponent("watch/")
            let servers = try await html(watch, referer: match.url, headers: headers)
            let ajax = try url("wp-content/themes/movies2023/Ajaxat/Single/Server.php")
            return servers.all { $0.tag == "li" && $0.hasClass("server--item") && !$0["data-id"].isEmpty }
                .compactMap { item -> HosterLink? in
                    let postID = item["data-id"], index = item["data-server"]
                    guard !index.isEmpty else { return nil }
                    let label = item.first { $0.tag == "span" }?.text ?? "Server \(index)"
                    let provider = self
                    return HosterLink(
                        name: label.trimmingCharacters(in: .whitespacesAndNewlines),
                        url: ajax.appendingPathComponent("\(postID)-\(index)"),
                        referer: watch,
                        resolveOverride: {
                            let body = try await provider.text(
                                ajax,
                                referer: watch,
                                headers: ["User-Agent": Self.userAgent, "X-Requested-With": "XMLHttpRequest"],
                                form: ["id": postID, "i": index]
                            )
                            guard let src = AnimeHTML.parse(body).first({ $0.tag == "iframe" })?["src"],
                                  let embed = ProviderNetwork.absolute(src, relativeTo: provider.baseURL) else {
                                throw AppError.invalidResponse
                            }
                            return try await HosterResolver(client: provider.client).resolve(embed, referer: watch)
                        }
                    )
                }
        }
        return []
    }

    /// Card titles read `فيلم <Title> <Year> مترجم اون لاين`; keep the Latin title.
    private static func result(from raw: String, url: URL) -> ScrapedResult {
        let decoded = raw.replacingOccurrences(of: "&#8211;", with: "-")
        let year = AnimeHTML.captures(#"\b((?:19|20)\d{2})\b"#, in: decoded).last.flatMap { Int($0[1]) }
        var title = decoded.unicodeScalars.filter { !(0x0600...0x06FF).contains($0.value) }.map(String.init).joined()
        if let year { title = title.replacingOccurrences(of: String(year), with: "") }
        return ScrapedResult(title: title.trimmingCharacters(in: .whitespacesAndNewlines), year: year, kind: .movie, url: url)
    }
}

// MARK: - Onlyflix

/// WordPress site. Title cards carry `data-title`/`data-year`/`data-url`;
/// movie and episode pages expose `data-player-post-id`/`data-player-nonce`,
/// and `admin-ajax.php action=mcp_get_available_players` returns the embeds.
struct OnlyflixPlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "onlyflix" }
    var displayName: String { "Onlyflix" }
    var baseURL: URL { URL(string: "https://onlyflix.to/")! }

    private static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        let headers = ["User-Agent": Self.userAgent]
        let isSeries = context.request.media.kind == .series
        for query in TitleMatch.queries(for: context) {
            guard let page = try? await html(try url("", query: ["s": query]), headers: headers) else { continue }
            let results: [ScrapedResult] = page.all { !$0["data-ofa-kind"].isEmpty && !$0["data-url"].isEmpty }.compactMap { card in
                guard let link = try? url(card["data-url"]) else { return nil }
                let kind: MediaKind = card["data-ofa-kind"].contains("tv") ? .series : .movie
                return ScrapedResult(title: card["data-title"], year: Int(card["data-year"]), kind: kind, url: link)
            }
            guard let match = results.bestMatch(for: context) else { continue }
            var target = match.url
            var detail = try await html(target, headers: headers)
            if isSeries {
                guard let episode = context.request.episode else { return [] }
                let marker = String(format: "-s%02de%02d", episode.seasonNumber, episode.number)
                guard let anchor = detail.first({ $0.tag == "a" && $0["href"].contains("/episodes/") && $0["href"].contains(marker) }),
                      let episodeURL = try? url(anchor["href"]) else { return [] }
                target = episodeURL
                detail = try await html(target, referer: match.url, headers: headers)
            }
            guard let player = detail.first({ !$0["data-player-post-id"].isEmpty }) else { return [] }
            let response = try await jsonObject(
                try url("wp-admin/admin-ajax.php"),
                referer: target,
                headers: ["User-Agent": Self.userAgent, "X-Requested-With": "XMLHttpRequest"],
                form: [
                    "action": "mcp_get_available_players",
                    "post_id": player["data-player-post-id"],
                    "nonce": player["data-player-nonce"],
                    "type": player["data-player-content-type"],
                ]
            )
            let players = (response["data"] as? [String: Any])?["players"] as? [[String: Any]] ?? []
            return players.compactMap { entry in
                guard let raw = entry["url"] as? String, let embed = URL(string: raw) else { return nil }
                let name = (entry["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? embed.host ?? "Server"
                let language = (entry["language"] as? String)?.lowercased()
                return HosterLink(name: name, url: embed, referer: target, audioLanguage: language?.isEmpty == false ? language : nil)
            }
        }
        return []
    }
}

// MARK: - NetPrime

/// NetPrime keys everything on TMDB ids and serves a fixed set of embed
/// APIs, so there is nothing to scrape: the server list is built directly.
struct NetPrimePlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "netprime" }
    var displayName: String { "NetPrime" }
    var baseURL: URL { URL(string: "https://netprime.gd/")! }

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        guard let target = NetPrimeEmbeds.Target(context: context) else { return [] }
        if context.request.media.kind == .series, !target.isEpisode { return [] }
        async let primeSrc = NetPrimeEmbeds.primeSrc(target)
        async let vidrock = NetPrimeEmbeds.vidrock(target)
        var links = NetPrimeEmbeds.vidzee(target)
        links += await primeSrc
        links += await vidrock
        links += NetPrimeEmbeds.videasy(target)
        links += NetPrimeEmbeds.embeds(target)
        return links.map { link in
            HosterLink(
                name: "NetPrime • \(link.name)",
                url: link.url,
                referer: link.referer,
                audioLanguage: link.audioLanguage,
                isDirect: link.isDirect,
                headers: link.headers,
                subtitles: link.subtitles,
                resolveOverride: link.resolveOverride
            )
        }
    }
}

// MARK: - Movy

/// movy.sx streams come from api.wecollege.net keyed on the TMDB id: a
/// short-lived seed, then per-city `sources` answered as an `enc=2` blob.
/// Both hosts sit behind Cloudflare, so requests go through CloudflareResolver.
struct MovyPlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "movy" }
    var displayName: String { "Movy" }
    var baseURL: URL { URL(string: "https://movy.sx/")! }

    private static let api = "https://api.wecollege.net"
    private static let cities: [(city: String, label: String, language: String)] = [
        ("miami", "Miami", "en"), ("portland", "Portland", "en"), ("austin", "Austin", "en"),
        ("dallas", "Dallas", "en"), ("munich", "Munich", "de"), ("berlin", "Berlin", "de"),
        ("paris", "Paris", "fr"), ("delhi", "Delhi", "hi"), ("cancun", "Cancun", "es"),
    ]

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        guard let target = NetPrimeEmbeds.Target(context: context) else { return [] }
        if context.request.media.kind == .series, !target.isEpisode { return [] }
        let referer = baseURL
        guard let seedURL = URL(string: "\(Self.api)/seed?mediaId=\(target.tmdbID)"),
              let seedText = try? await CloudflareResolver.get(seedURL, referer: referer, acceptsJSON: true, isUsable: {
                  $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
              }).text,
              !seedText.trimmingCharacters(in: .whitespaces).hasPrefix("<") else { return [] }
        let seedObject = (try? JSONSerialization.jsonObject(with: Data(seedText.utf8))) as? [String: Any]
        let seed = (seedObject?["seed"] as? String)
            ?? seedText.trimmingCharacters(in: CharacterSet(charactersIn: "\" \n\r\t"))
        guard !seed.isEmpty else { return [] }

        let results = await withTaskGroup(of: (Int, HosterLink?).self) { group in
            for (index, entry) in Self.cities.enumerated() {
                group.addTask {
                    (index, await Self.link(city: entry.city, label: entry.label, language: entry.language,
                                            seed: seed, target: target, referer: referer))
                }
            }
            var collected: [(Int, HosterLink?)] = []
            for await item in group { collected.append(item) }
            return collected
        }
        return results.sorted { $0.0 < $1.0 }.compactMap(\.1)
    }

    private static func link(
        city: String, label: String, language: String,
        seed: String, target: NetPrimeEmbeds.Target, referer: URL
    ) async -> HosterLink? {
        var components = URLComponents(string: "\(api)/\(city)/sources")
        var items = [
            URLQueryItem(name: "enc", value: "2"),
            URLQueryItem(name: "seed", value: seed),
            URLQueryItem(name: "title", value: target.title),
            URLQueryItem(name: "mediaType", value: target.isEpisode ? "tv" : "movie"),
            URLQueryItem(name: "tmdbId", value: String(target.tmdbID)),
        ]
        if let year = target.year { items.append(URLQueryItem(name: "year", value: String(year))) }
        if let imdb = target.imdbID { items.append(URLQueryItem(name: "imdbId", value: imdb)) }
        if let season = target.season, let episode = target.episode {
            items.append(URLQueryItem(name: "seasonId", value: String(season)))
            items.append(URLQueryItem(name: "episodeId", value: String(episode)))
        }
        components?.queryItems = items
        guard let url = components?.url,
              let response = try? await CloudflareResolver.get(url, referer: referer, acceptsJSON: true, isUsable: {
                  !$0.contains("<") && $0.count > 16
              }),
              (200...299).contains(response.statusCode) else { return nil }
        let body = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let plain = MovyCipher.decrypt(body, seed: seed, mediaID: target.tmdbID) ?? body
        guard let root = (try? JSONSerialization.jsonObject(with: Data(plain.utf8))) as? [String: Any],
              let sources = root["sources"] as? [[String: Any]] else { return nil }
        let best = sources.compactMap { source -> (url: URL, quality: Int)? in
            guard let raw = source["url"] as? String, let stream = URL(string: raw) else { return nil }
            let quality = Int(String(describing: source["quality"] ?? "").filter(\.isNumber)) ?? 0
            return (stream, quality)
        }.max { $0.quality < $1.quality }
        guard let stream = best?.url else { return nil }
        let subtitles = (root["subtitles"] as? [[String: Any]] ?? []).compactMap { track -> SubtitleSource? in
            guard let raw = track["url"] as? String, let file = URL(string: raw) else { return nil }
            let lang = (track["lang"] as? String) ?? "Unknown"
            return SubtitleSource(providerID: "movy", providerName: "Movy", label: lang,
                                  languageCode: AnimeStreamResolver.languageCode(lang), url: file)
        }
        let headers = ["User-Agent": HTTPClient.desktopUserAgent, "Referer": referer.absoluteString]
        return HosterLink(
            name: "Movy \(label) (\(language.uppercased()))",
            url: stream,
            referer: referer,
            audioLanguage: language,
            isDirect: true,
            headers: headers,
            subtitles: subtitles,
            resolveOverride: {
                PlaybackSource(url: stream, headers: headers, subtitles: subtitles, preferredPeakBitRate: nil)
            }
        )
    }
}

/// Port of movy.sx's `enc=2` response cipher (from the site's Next.js chunk):
/// a seed-scoped XOR keystream whose plaintext starts with the "mvm1" magic.
enum MovyCipher {
    private static func mix(_ value: UInt32) -> UInt32 {
        var e = value
        e ^= e >> 16
        e = e &* 0x85eb_ca6b
        e ^= e >> 13
        e = e &* 0xc2b2_ae35
        e ^= e >> 16
        return e
    }

    private static func rotl(_ value: UInt32, _ shift: Int) -> UInt32 {
        let s = UInt32(shift & 31)
        return s == 0 ? value : (value << s) | (value >> (32 - s))
    }

    private static func fnv(_ text: String) -> UInt32 {
        var hash: UInt32 = 0x811c_9dc5
        for unit in text.utf16 { hash = (hash ^ UInt32(unit)) &* 0x0100_0193 }
        return mix(hash)
    }

    static func decrypt(_ body: String, seed: String, mediaID: Int) -> String? {
        guard let bytes = ExtendedCrypto.b64Decode(body), bytes.count > 4 else { return nil }
        let golden: UInt32 = 0x9e37_79b9
        var state = [UInt32](repeating: 0, count: 61)
        var n = mix(fnv(seed) ^ mix(UInt32(truncatingIfNeeded: mediaID) ^ golden))
        for e in 0..<8 {
            let a = Int(n % 61)
            n = rotl(n &+ golden, 7 + (7 & e))
            state[a] = n ^ mix(n)
            n = mix(n &+ UInt32(a))
        }
        var acc = mix(0xa5a5_a5a5 ^ n)
        var output = [UInt8](repeating: 0, count: bytes.count)
        var counter: UInt32 = 0
        var index = 0
        while index < bytes.count {
            let d = Int(acc % 61)
            let s = state[d] ^ (golden &* (counter &+ 1))
            counter &+= 1
            var b = (acc ^ s) | (acc & s)
            b = rotl(b &+ acc, d & 31) ^ rotl(acc, (d * 7) & 31)
            let block = mix(b &+ golden)
            state[d] = block
            acc = block
            for k in 0..<4 where index < bytes.count {
                output[index] = bytes[index] ^ UInt8(truncatingIfNeeded: block >> UInt32(8 * k))
                index += 1
            }
        }
        guard output.starts(with: Array("mvm1".utf8)) else { return nil }
        return String(bytes: output.dropFirst(4), encoding: .utf8)
    }
}
