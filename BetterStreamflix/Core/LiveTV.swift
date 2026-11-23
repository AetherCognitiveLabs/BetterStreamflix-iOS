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
