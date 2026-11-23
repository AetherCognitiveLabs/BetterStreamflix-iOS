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

    func channels() async throws -> [LiveChannel] {
        let wanted = Set(groupNames.map { $0.lowercased() })
        let id = id
        return try await Self.catalog().compactMap { item in
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

    func resolve(_ channel: LiveChannel) async throws -> PlaybackSource {
        for site in Self.sites {
            var components = URLComponents(url: site.appendingPathComponent("live/resolve"), resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "url", value: channel.streamURL.absoluteString)]
            guard let url = components?.url,
                  let object = try? await Self.json(url) as? [String: Any],
                  let raw = (object["url"] as? String) ?? (object["streamUrl"] as? String),
                  let stream = URL(string: raw) else { continue }
            return PlaybackSource(url: stream, headers: Self.playHeaders(for: channel.streamURL), subtitles: [], preferredPeakBitRate: nil)
        }
        throw AppError.invalidResponse
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
            M3UPlaylistLiveProvider.iptvOrg
        ]
    }
}
