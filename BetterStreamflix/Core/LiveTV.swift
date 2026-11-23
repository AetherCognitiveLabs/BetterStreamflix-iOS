import Foundation

/// A playable live channel: an endless HLS (or other direct) stream plus the
/// headers the origin expects. EPG fields are optional; most playlists only
/// carry a guide id.
struct LiveChannel: Identifiable, Hashable, Sendable {
    let id: String
    let providerID: String
    let name: String
    let logo: URL?
    let group: String?
    let streamURL: URL
    var headers: [String: String] = [:]
    var epgID: String? = nil
    var programNow: String? = nil
    var programNext: String? = nil
    var channelNumber: Int? = nil

    var playbackSource: PlaybackSource {
        PlaybackSource(url: streamURL, headers: headers, subtitles: [], preferredPeakBitRate: nil)
    }
}

struct LiveChannelGroup: Identifiable, Hashable, Sendable {
    let name: String
    let channels: [LiveChannel]
    var id: String { name }
}

/// Lists live channels. `resolve` lets providers whose list entries are not
/// directly playable (signed tokens, embed pages) produce the stream at play time.
protocol LiveTVProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    var language: String { get }
    func channels() async throws -> [LiveChannel]
    func resolve(_ channel: LiveChannel) async throws -> PlaybackSource
}

extension LiveTVProvider {
    func resolve(_ channel: LiveChannel) async throws -> PlaybackSource { channel.playbackSource }

    /// Channels grouped by `group` (ungrouped go to "General"), groups sorted by name.
    func groups() async throws -> [LiveChannelGroup] {
        LiveChannelGroup.grouping(try await channels())
    }
}

extension LiveChannelGroup {
    static func grouping(_ channels: [LiveChannel]) -> [LiveChannelGroup] {
        var order: [String] = []
        var buckets: [String: [LiveChannel]] = [:]
        for channel in channels {
            let name = channel.group?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "General"
            if buckets[name] == nil { order.append(name) }
            buckets[name, default: []].append(channel)
        }
        return order.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { LiveChannelGroup(name: $0, channels: buckets[$0] ?? []) }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// M3U / M3U8 playlist parser, ported from BetterStreamflix Android's
/// M3uPlaylistParser: tolerates bare `EXTINF:` lines, reads per-channel
/// headers from attributes, `#EXTVLCOPT` and `url|Header=value` suffixes, and
/// drops placeholder hosts that never play.
enum M3UPlaylistParser {
    struct Entry: Hashable, Sendable {
        let name: String
        let url: URL
        let logo: String?
        let group: String?
        let tvgID: String?
        let channelNumber: Int?
        let headers: [String: String]
    }

    private static let deadHostMarkers = ["sinurl.com", "example.com", "example.org", "0.0.0.0", "127.0.0.1", "localhost", "about:blank"]

    static func isPlayable(_ raw: String) -> Bool {
        let lower = raw.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return false }
        return !deadHostMarkers.contains(where: lower.contains)
    }

    static func parse(_ raw: String) -> [Entry] {
        var entries: [Entry] = []
        var name = "", logo = "", group = "", tvgID = "", number = ""
        var userAgent: String?, referrer: String?, origin: String?
        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let upper = trimmed.uppercased()
            if upper.hasPrefix("#EXTINF") || upper.hasPrefix("EXTINF") {
                let label = trimmed.contains(",") ? trimmed.components(separatedBy: ",").last?.trimmingCharacters(in: .whitespaces) ?? "" : ""
                name = label.isEmpty ? attribute("tvg-name", in: trimmed) : label
                logo = attribute("tvg-logo", in: trimmed)
                group = attribute("group-title", in: trimmed)
                tvgID = attribute("tvg-id", in: trimmed)
                number = attribute("tvg-chno", in: trimmed)
                userAgent = attribute("http-user-agent", in: trimmed).nonEmpty
                referrer = attribute("http-referrer", in: trimmed).nonEmpty
                origin = attribute("http-origin", in: trimmed).nonEmpty
                continue
            }
            if upper.hasPrefix("#EXTVLCOPT:") {
                for (key, apply) in [("http-user-agent=", 0), ("http-referrer=", 1), ("http-origin=", 2)] {
                    guard let range = trimmed.range(of: key, options: .caseInsensitive) else { continue }
                    let value = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    switch apply {
                    case 0: userAgent = value
                    case 1: referrer = value
                    default: origin = value
                    }
                }
                continue
            }
            if trimmed.hasPrefix("#") { continue }
            guard isPlayable(trimmed) else { continue }
            var parts = trimmed.components(separatedBy: "|")
            let urlString = parts.removeFirst()
            var pipeUA: String?, pipeReferrer: String?, pipeOrigin: String?
            for part in parts.flatMap({ $0.components(separatedBy: "&") }) {
                let pair = part.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
                guard pair.count == 2, !pair[1].isEmpty else { continue }
                switch pair[0].lowercased() {
                case "user-agent", "http-user-agent": pipeUA = pair[1]
                case "referer", "referrer", "http-referrer": pipeReferrer = pair[1]
                case "origin", "http-origin": pipeOrigin = pair[1]
                default: break
                }
            }
            guard !name.isEmpty, isPlayable(urlString), let url = URL(string: urlString) else { continue }
            var headers: [String: String] = [:]
            if let value = pipeUA ?? userAgent { headers["User-Agent"] = value }
            if let value = pipeReferrer ?? referrer { headers["Referer"] = value }
            if let value = pipeOrigin ?? origin { headers["Origin"] = value }
            entries.append(Entry(
                name: name, url: url, logo: logo.nonEmpty, group: group.nonEmpty,
                tvgID: tvgID.nonEmpty, channelNumber: Int(number), headers: headers
            ))
            name = ""; logo = ""; group = ""; tvgID = ""; number = ""
            userAgent = nil; referrer = nil; origin = nil
        }
        return entries
    }

    private static func attribute(_ key: String, in line: String) -> String {
        for quote in ["\"", "'"] {
            let pattern = "\(key)=\(quote)([^\(quote)]*)\(quote)"
            if let range = line.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                let match = String(line[range])
                return String(match.dropFirst(key.count + 2).dropLast())
            }
        }
        return ""
    }
}

private actor LivePlaylistCache {
    static let shared = LivePlaylistCache()
    private var entries: [String: (fetchedAt: Date, channels: [LiveChannel])] = [:]
    private var inFlight: [String: Task<[LiveChannel], Error>] = [:]

    func channels(
        for key: String,
        maxAge: TimeInterval,
        load: @escaping @Sendable () async throws -> [LiveChannel]
    ) async throws -> [LiveChannel] {
        if let cached = entries[key], Date().timeIntervalSince(cached.fetchedAt) < maxAge {
            return cached.channels
        }
        if let task = inFlight[key] { return try await task.value }
        let task = Task { try await load() }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        do {
            let channels = try await task.value
            entries[key] = (Date(), channels)
            return channels
        } catch {
            if let stale = entries[key]?.channels, !stale.isEmpty { return stale }
            throw error
        }
    }
}

/// Providers backed by a single public M3U playlist (Pluto TV regional
/// playlists, IPTV-org), ported from BetterStreamflix Android's
/// PlutoTv*Provider / IptvOrgProvider. Playlists are cached for 30 minutes.
struct M3UPlaylistLiveProvider: LiveTVProvider {
    let id: String
    let displayName: String
    let language: String
    let playlistURL: URL

    static let fetchUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/118.0.0.0 Safari/537.36"

    static let plutoTVDE = M3UPlaylistLiveProvider(
        id: "plutotvde", displayName: "Pluto TV DE", language: "de",
        playlistURL: URL(string: "https://raw.githubusercontent.com/BuddyChewChew/app-m3u-generator/main/playlists/plutotv_de.m3u")!
    )
    static let plutoTVUS = M3UPlaylistLiveProvider(
        id: "plutotvus", displayName: "Pluto TV US", language: "en",
        playlistURL: URL(string: "https://raw.githubusercontent.com/BuddyChewChew/app-m3u-generator/main/playlists/plutotv_us.m3u")!
    )
    static let iptvOrg = M3UPlaylistLiveProvider(
        id: "iptvorg", displayName: "IPTV-org", language: "multi",
        playlistURL: URL(string: "https://iptv-org.github.io/iptv/index.m3u")!
    )

    func channels() async throws -> [LiveChannel] {
        let id = id, url = playlistURL
        return try await LivePlaylistCache.shared.channels(for: id, maxAge: 30 * 60) {
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.setValue(Self.fetchUserAgent, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw AppError.invalidResponse
            }
            let text = String(decoding: data, as: UTF8.self)
            var seen: Set<String> = []
            let channels = M3UPlaylistParser.parse(text).compactMap { entry -> LiveChannel? in
                guard seen.insert(entry.name.lowercased()).inserted else { return nil }
                return LiveChannel(
                    id: "\(id):\(entry.tvgID ?? entry.url.absoluteString)",
                    providerID: id,
                    name: entry.name,
                    logo: entry.logo.flatMap(URL.init(string:)),
                    group: entry.group.map { $0.components(separatedBy: ";").first ?? $0 },
                    streamURL: entry.url,
                    headers: entry.headers,
                    epgID: entry.tvgID,
                    channelNumber: entry.channelNumber
                )
            }
            if channels.isEmpty { throw AppError.invalidResponse }
            return channels
        }
    }
}

/// Vavoo live TV via the token-free geil.to catalog, ported from BetterStreamflix
/// Android's VavooProvider primary path: the paged catalog is filtered to the
/// language's country groups and each channel is resolved right before playback.
struct VavooLiveProvider: LiveTVProvider {
    let id: String
    let displayName: String
    let language: String
    let groupNames: [String]

    private static let sites = ["https://geil.to", "https://geil.app", "https://geil.win"].compactMap(URL.init(string:))
    private static let apiUserAgent = "MediaHubMX/2"
    private static let playUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Safari/537.36"

    static let de = VavooLiveProvider(id: "vavoo", displayName: "Vavoo Live DE", language: "de", groupNames: ["Germany"])
    static let en = VavooLiveProvider(id: "vavooEn", displayName: "Vavoo Live UK", language: "en", groupNames: ["United Kingdom"])
    static let it = VavooLiveProvider(id: "vavooIt", displayName: "Vavoo Live IT", language: "it", groupNames: ["Italy"])
    static let fr = VavooLiveProvider(id: "vavooFr", displayName: "Vavoo Live FR", language: "fr", groupNames: ["France", "France Sport"])
    static let es = VavooLiveProvider(id: "vavooEs", displayName: "Vavoo Live ES", language: "es", groupNames: ["Spain"])
    static let pl = VavooLiveProvider(id: "vavooPl", displayName: "Vavoo Live PL", language: "pl", groupNames: ["Poland"])

    private static let vavooBase = URL(string: "https://vavoo.to")!
    private static let browserUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"

    private var apiRegion: String {
        ["de": "DE", "en": "GB", "it": "IT", "fr": "FR", "es": "ES", "pl": "PL"][language] ?? language.uppercased()
    }

    func channels() async throws -> [LiveChannel] {
        let items: [CatalogItem]
        do {
            items = try await Self.catalog()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return try await mediaHubChannels()
        }
        let wanted = Set(groupNames.map { $0.lowercased() })
        let id = id
        return items.compactMap { item in
            guard wanted.contains(item.group.lowercased()) else { return nil }
            return LiveChannel(
                id: "\(id):\(item.id)",
                providerID: id,
                name: item.name,
                logo: item.logo,
                group: Self.category(for: item.name),
                streamURL: item.url,
                headers: Self.playHeaders(for: item.url),
                epgID: item.tvgID
            )
        }
    }

    /// Resolve order from Android: geil.to mirror, unsigned MediaHub resolve,
    /// signed MediaHubMX/MediaUrl passes (re-signing once on 401/403/451),
    /// then geil.to again for non-geil URLs.
    func resolve(_ channel: LiveChannel) async throws -> PlaybackSource {
        let target = channel.streamURL
        let headers = Self.playHeaders(for: target)
        func source(_ url: URL) -> PlaybackSource {
            PlaybackSource(url: url, headers: headers, subtitles: [], preferredPeakBitRate: nil)
        }
        let isGeil = target.host?.lowercased().contains("geil.") == true
        if isGeil, let url = await Self.geilResolve(target) { return source(url) }

        let bases = Self.resolveBases(for: target)
        for base in bases {
            let body: [String: Any] = ["language": language, "region": apiRegion, "url": target.absoluteString]
            if let result = try? await Self.post(base.appendingPathComponent("mediahubmx-resolve.json"), body: body, headers: Self.browserHeaders(base)),
               let url = Self.parseResolved(result.data, status: result.status) {
                return source(url)
            }
        }

        try Task.checkCancellation()
        if let signature = await VavooAddonSignature.shared.current() {
            let first = await signedPass(target, bases: bases, signature: signature)
            if let url = first.url { return source(url) }
            if first.authFailure {
                await VavooAddonSignature.shared.invalidate()
                if let fresh = await VavooAddonSignature.shared.current(force: true),
                   let url = await signedPass(target, bases: bases, signature: fresh).url {
                    return source(url)
                }
            }
        }

        if !isGeil, let url = await Self.geilResolve(target) { return source(url) }
        throw AppError.invalidResponse
    }

    private func signedPass(
        _ target: URL,
        bases: [URL],
        signature: VavooAddonSignature.Signature
    ) async -> (url: URL?, authFailure: Bool) {
        var authFailure = false
        let plans: [(VavooMediaEngine, String)] = [
            (.mediaHubMX, "3.1.0"), (.mediaURL, "3.1.0"), (.mediaHubMX, "3.0.2"), (.mediaURL, "3.0.2")
        ]
        for base in bases {
            for (engine, clientVersion) in plans {
                let body: [String: Any] = [
                    "language": language, "region": apiRegion,
                    "url": target.absoluteString, "clientVersion": clientVersion
                ]
                let headers = ["User-Agent": engine.userAgent, "Accept": "application/json", engine.signatureHeader: signature.value]
                guard let result = try? await Self.post(base.appendingPathComponent("\(engine.prefix)-resolve.json"), body: body, headers: headers) else { continue }
                if let url = Self.parseResolved(result.data, status: result.status) { return (url, authFailure) }
                if [401, 403, 451].contains(result.status) { authFailure = true }
            }
        }
        return (nil, authFailure)
    }

    /// Android's fallback channel list: vavoo.to's MediaHub catalog per group.
    /// Tried unsigned like Android, then with the addon signature.
    private func mediaHubChannels() async throws -> [LiveChannel] {
        let endpoint = Self.vavooBase.appendingPathComponent("mediahubmx-catalog.json")
        let signature = await VavooAddonSignature.shared.current()
        var channels: [LiveChannel] = []
        var seen: Set<String> = []
        for group in groupNames {
            for signed in [false, true] where channels.isEmpty || signed == false {
                if signed && signature == nil { continue }
                var cursor: Int?
                for _ in 0..<50 {
                    try Task.checkCancellation()
                    var body: [String: Any] = [
                        "language": language, "region": apiRegion, "catalogId": "iptv", "id": "",
                        "adult": false, "search": "", "sort": "name", "filter": ["group": group],
                        "cursor": cursor.map { $0 as Any } ?? NSNull()
                    ]
                    var headers = Self.browserHeaders(Self.vavooBase)
                    if signed, let signature {
                        body["clientVersion"] = "3.1.0"
                        headers = ["User-Agent": VavooMediaEngine.mediaHubMX.userAgent, "Accept": "application/json",
                                   VavooMediaEngine.mediaHubMX.signatureHeader: signature.value]
                    }
                    guard let result = try? await Self.post(endpoint, body: body, headers: headers),
                          (200..<300).contains(result.status),
                          let page = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any],
                          let rows = page["items"] as? [[String: Any]], !rows.isEmpty else { break }
                    for row in rows {
                        guard let raw = row["url"] as? String, let url = URL(string: raw),
                              let name = row["name"] as? String, !name.isEmpty else { continue }
                        let rowID = ((row["ids"] as? [String: Any])?["id"]).map { "\($0)" } ?? raw
                        guard seen.insert(rowID).inserted else { continue }
                        channels.append(LiveChannel(
                            id: "\(id):\(rowID)",
                            providerID: id,
                            name: Self.fixName(name),
                            logo: nil,
                            group: Self.category(for: name),
                            streamURL: url,
                            headers: Self.playHeaders(for: url)
                        ))
                    }
                    guard let next = page["nextCursor"] as? Int else { break }
                    cursor = next
                }
            }
        }
        guard !channels.isEmpty else { throw AppError.invalidResponse }
        return channels
    }

    private static func geilResolve(_ target: URL) async -> URL? {
        for site in sites {
            var components = URLComponents(url: site.appendingPathComponent("live/resolve"), resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "url", value: target.absoluteString)]
            guard let url = components?.url,
                  let object = try? await json(url) as? [String: Any],
                  let raw = (object["url"] as? String) ?? (object["streamUrl"] as? String),
                  let stream = URL(string: raw) else { continue }
            return stream
        }
        return nil
    }

    private static func resolveBases(for url: URL) -> [URL] {
        var bases: [URL] = []
        if let scheme = url.scheme, let host = url.host, let origin = URL(string: "\(scheme)://\(host)") { bases.append(origin) }
        bases.append(vavooBase)
        var seen: Set<String> = []
        return bases.filter { seen.insert($0.absoluteString.lowercased()).inserted }
    }

    private static func browserHeaders(_ base: URL) -> [String: String] {
        let origin = base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return ["User-Agent": browserUserAgent, "Origin": origin, "Referer": origin + "/"]
    }

    private static func post(_ url: URL, body: [String: Any], headers: [String: String]) async throws -> (data: Data, status: Int) {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private static func parseResolved(_ data: Data, status: Int) -> URL? {
        guard (200..<300).contains(status), let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let object: [String: Any]?
        if let array = json as? [[String: Any]] {
            object = array.first
        } else if let top = json as? [String: Any] {
            object = (top["data"] as? [String: Any]) ?? (top["result"] as? [String: Any]) ?? top
        } else {
            object = nil
        }
        guard let raw = object?["url"] as? String, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    private struct CatalogItem: Sendable {
        let id: String, name: String, url: URL, logo: URL?, group: String, tvgID: String?
    }

    private static func playHeaders(for url: URL) -> [String: String] {
        var headers = ["User-Agent": playUserAgent]
        if let scheme = url.scheme, let host = url.host { headers["Referer"] = "\(scheme)://\(host)/" }
        return headers
    }

    private static func json(_ url: URL) async throws -> Any {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(apiUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw AppError.invalidResponse }
        return try JSONSerialization.jsonObject(with: data)
    }

    private static let catalogCache = LiveCatalogCache<[CatalogItem]>()

    private static func catalog() async throws -> [CatalogItem] {
        try await catalogCache.value(maxAge: 30 * 60) {
            for site in sites {
                var items: [CatalogItem] = []
                var cursor: String?
                do {
                    for _ in 0..<200 {
                        try Task.checkCancellation()
                        var components = URLComponents(url: site.appendingPathComponent("live/catalog/live/channels.json"), resolvingAgainstBaseURL: false)
                        if let cursor { components?.queryItems = [URLQueryItem(name: "cursor", value: cursor)] }
                        guard let url = components?.url,
                              let page = try await json(url) as? [String: Any],
                              let rows = page["items"] as? [[String: Any]], !rows.isEmpty else { break }
                        for row in rows {
                            guard let id = row["id"].map({ "\($0)" }), !id.isEmpty,
                                  let raw = row["url"] as? String, let url = URL(string: raw) else { continue }
                            let logo = ((row["images"] as? [String: Any])?["logo"] as? String).map(fixLogo)
                            items.append(CatalogItem(
                                id: id,
                                name: fixName(row["name"] as? String ?? ""),
                                url: url,
                                logo: logo.flatMap(URL.init(string:)),
                                group: (row["tags"] as? [String])?.first ?? "",
                                tvgID: (row["ids"] as? [String: Any])?["tvg"] as? String
                            ))
                        }
                        guard let next = page["nextCursor"] as? String, !next.isEmpty, next != "null" else { break }
                        cursor = next
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    continue
                }
                if items.count >= 100 { return items }
            }
            throw AppError.invalidResponse
        }
    }

    /// geil.to marks mirrors as "Name (1)"; Android maps them to Vavoo's ".b/.c/.s" suffixes.
    private static func fixName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let range = trimmed.range(of: #"\s*\((\d{1,2})\)$"#, options: .regularExpression) else { return name }
        let number = trimmed[range].filter(\.isNumber)
        let tag = ["1": "b", "6": "c", "7": "s"][String(number)] ?? String(number)
        return trimmed[..<range.lowerBound].trimmingCharacters(in: .whitespaces) + " .\(tag)"
    }

    private static func fixLogo(_ raw: String) -> String {
        if let range = raw.range(of: #"^https?://logo\.huhu\.to/logo\?c=(\d+)\.png$"#, options: .regularExpression) {
            let number = raw[range].components(separatedBy: "c=").last?.replacingOccurrences(of: ".png", with: "") ?? ""
            return "https://vavoo.to/live2/logo/\(number).png"
        }
        if raw.hasPrefix("/live2/logo/") { return "https://vavoo.to" + raw }
        return raw
    }

    private static func category(for name: String) -> String {
        let value = name.lowercased()
        let words: [(String, [String])] = [
            ("Sport", ["sport", "dazn", "eurosport", "sky sport", "bundesliga", "football", "calcio", "futbol", "tennis"]),
            ("News", ["news", "nachrichten", "n-tv", "ntv", "welt", "tagesschau", "cnn", "bbc news", "rai news", "euronews"]),
            ("Doku", ["doku", "discovery", "national geographic", "nat geo", "history", "planet", "animal"]),
            ("Film", ["cinema", "kino", "film", "movie", "sky cinema", "action", "thriller"])
        ]
        return words.first { $0.1.contains(where: value.contains) }?.0 ?? "TV"
    }
}

/// Sports events and 24/7 channels from the ppv.st API that SportsBite uses,
/// ported from BetterStreamflix Android's SportsBiteProvider. Entries point at
/// embed pages; the HLS URL is scraped from the embed (or a nested iframe or a
/// known mirror host) right before playback.
struct SportsBiteLiveProvider: LiveTVProvider {
    var id: String { "sportsbite" }
    var displayName: String { "SportsBite" }
    var language: String { "multi" }

    private static let site = URL(string: "https://sportsbite.org")!
    private static let streamsAPI = URL(string: "https://api.ppv.st/api/streams")!
    private static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    private static let mirrorHosts = ["embed.ppv.st", "embed.cr7siuu.xyz", "embed.weakstream.xyz", "embedstreams.net"]
    private static let cache = LiveCatalogCache<[LiveChannel]>()

    func channels() async throws -> [LiveChannel] {
        let id = id
        return try await Self.cache.value(maxAge: 10 * 60) {
            var request = URLRequest(url: Self.streamsAPI, timeoutInterval: 20)
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(Self.site.absoluteString, forHTTPHeaderField: "Origin")
            request.setValue(Self.site.absoluteString + "/", forHTTPHeaderField: "Referer")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw AppError.invalidResponse }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let categories = root["streams"] as? [[String: Any]] else { throw AppError.invalidResponse }
            var result: [LiveChannel] = []
            for category in categories {
                let categoryName = (category["category"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Sports"
                for stream in category["streams"] as? [[String: Any]] ?? [] {
                    guard let name = (stream["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                          let iframe = (stream["iframe"] as? String)?.trimmingCharacters(in: .whitespaces),
                          let embed = URL(string: iframe), embed.scheme?.hasPrefix("http") == true else { continue }
                    let key = (stream["uri_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? stream["id"].map { "\($0)" } ?? iframe
                    let poster = (stream["poster"] as? String) ?? (stream["image"] as? String)
                    let group = (stream["category_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? categoryName
                    let tag = (stream["tag"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    let startsAt = (stream["starts_at"] as? Double) ?? 0
                    let alwaysLive = (stream["always_live"] as? Int) == 1 || (stream["always_live"] as? Bool) == true
                    var channel = LiveChannel(
                        id: "\(id):\(key)", providerID: id, name: name,
                        logo: poster.flatMap(URL.init(string:)), group: group,
                        streamURL: embed, headers: ["User-Agent": Self.userAgent, "Referer": Self.site.absoluteString + "/"]
                    )
                    if alwaysLive {
                        channel.programNow = tag ?? "24/7"
                    } else if startsAt > 0 {
                        let start = Date(timeIntervalSince1970: startsAt)
                        channel.programNow = start <= Date() ? "Live now" : "Starts \(start.formatted(date: .abbreviated, time: .shortened))"
                    }
                    result.append(channel)
                }
            }
            if result.isEmpty { throw AppError.invalidResponse }
            return result
        }
    }

    func resolve(_ channel: LiveChannel) async throws -> PlaybackSource {
        let embed = channel.streamURL
        if let html = try? await Self.html(embed, referer: Self.site) {
            if let stream = LiveStreamHTMLExtractor.m3u8(in: html) {
                return Self.source(stream, referer: embed)
            }
            if let nested = LiveStreamHTMLExtractor.embedURL(in: html),
               let nestedHTML = try? await Self.html(nested, referer: embed),
               let stream = LiveStreamHTMLExtractor.m3u8(in: nestedHTML) {
                return Self.source(stream, referer: nested)
            }
        }
        let raw = embed.absoluteString
        if raw.contains("embedindia.st") || raw.contains("embed.ppv.st") {
            for host in Self.mirrorHosts {
                let mirrored = raw.replacingOccurrences(of: "embedindia.st", with: host).replacingOccurrences(of: "embed.ppv.st", with: host)
                guard mirrored != raw, let url = URL(string: mirrored),
                      let html = try? await Self.html(url, referer: Self.site),
                      let stream = LiveStreamHTMLExtractor.m3u8(in: html) else { continue }
                return Self.source(stream, referer: url)
            }
        }
        throw AppError.invalidResponse
    }

    private static func source(_ stream: URL, referer: URL) -> PlaybackSource {
        PlaybackSource(url: stream, headers: ["User-Agent": userAgent, "Referer": referer.absoluteString], subtitles: [], preferredPeakBitRate: nil)
    }

    private static func html(_ url: URL, referer: URL) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw AppError.invalidResponse }
        return String(decoding: data, as: UTF8.self)
    }
}

/// HLS URL extraction from live embed pages, ported from BetterStreamflix
/// Android's LiveStreamHtmlExtractor (assigned SRC, file/source keys, atob
/// payloads, XOR arrays, then any .m3u8 literal, preferring master playlists).
enum LiveStreamHTMLExtractor {
    private static let adMarkers = ["exmxbxe.", "assetrage.", "llvpn.com", "histats.", "aclib.", "wpnxis", "blogspot.com"]

    static func m3u8(in html: String) -> URL? {
        guard !html.isEmpty else { return nil }
        let keyed = [
            #"(?:const|let|var)\s+SRC\s*=\s*["'](https?://[^"']+\.m3u8[^"']*)["']"#,
            #"(?:file|source|src|url)\s*[:=]\s*["'](https?://[^"']+\.m3u8[^"']*)["']"#,
            #"<source[^>]+src=["'](https?://[^"']+\.m3u8[^"']*)["']"#,
            #"["']file["']\s*:\s*["'](https?://[^"']+\.m3u8[^"']*)["']"#,
            #"sources?\s*:\s*\[\s*["'](https?://[^"']+\.m3u8[^"']*)["']"#
        ]
        for pattern in keyed {
            if let value = captures(pattern, in: html).first?[1], let url = URL(string: unescape(value)) { return url }
        }
        let chunks = captures(#"atob\(['"]([^'"]+)['"]\)"#, in: html).compactMap { decodeBase64($0[1]) }
        if let best = pickBest(chunks.filter { $0.hasPrefix("http") && $0.localizedCaseInsensitiveContains(".m3u8") }) {
            return URL(string: best)
        }
        if chunks.count >= 2 {
            let joined = chunks.joined()
            if joined.hasPrefix("http"), joined.localizedCaseInsensitiveContains(".m3u8") { return URL(string: joined) }
        }
        if let decoded = xorArray(in: html), let found = captures(#"https?://[^"'\\\s<>]+?\.m3u8[^"'\\\s<>]*"#, in: decoded).first?[0] {
            return URL(string: found)
        }
        let literals = captures(#"https?:(?:\\?/){2}[^"'\s<>]+?\.m3u8[^"'\s<>]*"#, in: html).map { unescape($0[0]) }
        if let best = pickBest(literals) { return URL(string: best) }
        let relative = captures(#"(?<![:\w])//[^"'\\\s<>]+?\.m3u8[^"'\\\s<>]*"#, in: html).map { "https:" + unescape($0[0]) }
        return pickBest(relative).flatMap(URL.init(string:))
    }

    static func embedURL(in html: String) -> URL? {
        var candidates: [String] = []
        for pattern in [
            #"<iframe[^>]+id=["']thatframe["'][^>]+src=["']([^"']+)["']"#,
            #"<iframe[^>]+src=["']([^"']+)["'][^>]+id=["']thatframe["']"#,
            #"<iframe[^>]+class=["'][^"']*video[^"']*["'][^>]+src=["']([^"']+)["']"#,
            #"<iframe[^>]+src=["'](https?://[^"']+)["']"#
        ] {
            candidates += captures(pattern, in: html).map { $0[1].trimmingCharacters(in: .whitespaces) }
        }
        let usable = candidates.filter { $0.lowercased().hasPrefix("http") && !adMarkers.contains(where: $0.lowercased().contains) }
        let preferred = usable.first { value in ["embed", "player", "stream", "premiumtv"].contains { value.localizedCaseInsensitiveContains($0) } }
        return (preferred ?? usable.first).flatMap(URL.init(string:))
    }

    private static func pickBest(_ candidates: [String]) -> String? {
        func score(_ url: String) -> Int {
            let lower = url.lowercased()
            var value = 0
            if lower.contains("master") { value += 40 }
            if lower.contains("index") { value += 25 }
            if lower.contains("playlist") { value += 15 }
            if lower.contains("chunklist") { value -= 20 }
            if adMarkers.contains(where: lower.contains) { value -= 100 }
            return value
        }
        return candidates.max { (score($0), $0.count) < (score($1), $1.count) }
    }

    private static func xorArray(in html: String) -> String? {
        guard let match = captures(#"var\s+_(\w+)=\[([^\]]+)\],_(\w+)=(\d+),_(\w+)=(\d+)"#, in: html).first,
              let xor = Int(match[4]), let sub = Int(match[6]) else { return nil }
        let bytes = match[2].split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .map { UInt8(truncatingIfNeeded: (($0 ^ xor) - sub + 256) & 255) }
        return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
    }

    private static func decodeBase64(_ value: String) -> String? {
        var padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded += "=" }
        return Data(base64Encoded: padded).map { String(decoding: $0, as: UTF8.self) }
    }

    private static func unescape(_ value: String) -> String { value.replacingOccurrences(of: "\\/", with: "/") }

    private static func captures(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            (0..<match.numberOfRanges).map { index in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
        }
    }
}

private actor LiveCatalogCache<Value: Sendable> {
    private var cached: (fetchedAt: Date, value: Value)?
    private var inFlight: Task<Value, Error>?

    func value(maxAge: TimeInterval, load: @escaping @Sendable () async throws -> Value) async throws -> Value {
        if let cached, Date().timeIntervalSince(cached.fetchedAt) < maxAge { return cached.value }
        if let inFlight { return try await inFlight.value }
        let task = Task { try await load() }
        inFlight = task
        defer { inFlight = nil }
        do {
            let value = try await task.value
            cached = (Date(), value)
            return value
        } catch {
            if let cached { return cached.value }
            throw error
        }
    }
}

enum LiveTVProviders {
    static func all() -> [any LiveTVProvider] {
        [
            M3UPlaylistLiveProvider.plutoTVDE, M3UPlaylistLiveProvider.plutoTVUS,
            VavooLiveProvider.de, VavooLiveProvider.en, VavooLiveProvider.it,
            VavooLiveProvider.fr, VavooLiveProvider.es, VavooLiveProvider.pl,
            SportsBiteLiveProvider(),
            M3UPlaylistLiveProvider.iptvOrg
        ]
    }
}
