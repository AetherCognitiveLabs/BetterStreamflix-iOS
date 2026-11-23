import Compression
import Foundation

struct LiveProgramme: Hashable, Sendable {
    let start: Date
    let stop: Date
    let title: String
}

/// Lazily fetched XMLTV programme guides keyed by channel guide ID
/// (`LiveChannel.epgID`). Guides are cached in memory and on disk for six
/// hours and only fetched when a provider with a guide is opened.
actor LiveEPG {
    static let shared = LiveEPG()

    /// XMLTV sources advertised by the providers' playlists (`url-tvg`),
    /// gzip first with the uncompressed mirror as fallback.
    static let guideSources: [String: [URL]] = [
        M3UPlaylistLiveProvider.plutoTVDE.id: [
            "https://github.com/matthuisman/i.mjh.nz/raw/master/PlutoTV/de.xml.gz",
            "https://i.mjh.nz/PlutoTV/de.xml"
        ].compactMap(URL.init(string:)),
        M3UPlaylistLiveProvider.plutoTVUS.id: [
            "https://github.com/matthuisman/i.mjh.nz/raw/master/PlutoTV/us.xml.gz",
            "https://i.mjh.nz/PlutoTV/us.xml"
        ].compactMap(URL.init(string:))
    ]

    private static let ttl: TimeInterval = 6 * 60 * 60
    private var guides: [String: (loaded: Date, programmes: [String: [LiveProgramme]])] = [:]
    private var inFlight: [String: Task<[String: [LiveProgramme]], Error>] = [:]

    static func hasGuide(_ providerID: String) -> Bool { guideSources[providerID] != nil }

    /// Returns `channels` with `programNow` / `programNext` filled from the
    /// provider's guide; unchanged when there is no guide or it fails to load.
    func annotate(_ channels: [LiveChannel], providerID: String, now: Date = Date()) async -> [LiveChannel] {
        guard Self.hasGuide(providerID), channels.contains(where: { $0.epgID != nil }),
              let guide = try? await guide(for: providerID) else { return channels }
        return channels.map { channel in
            guard let id = channel.epgID, let list = guide[id],
                  let index = list.firstIndex(where: { $0.stop > now }) else { return channel }
            var annotated = channel
            if list[index].start <= now {
                annotated.programNow = list[index].title
                annotated.programNext = list.indices.contains(index + 1) ? list[index + 1].title : nil
            } else {
                annotated.programNext = list[index].title
            }
            return annotated
        }
    }

    func guide(for providerID: String) async throws -> [String: [LiveProgramme]] {
        if let cached = guides[providerID], Date().timeIntervalSince(cached.loaded) < Self.ttl {
            return cached.programmes
        }
        if let running = inFlight[providerID] { return try await running.value }
        let sources = Self.guideSources[providerID] ?? []
        let task = Task.detached(priority: .utility) { try await Self.fetch(providerID: providerID, sources: sources) }
        inFlight[providerID] = task
        defer { inFlight[providerID] = nil }
        let programmes = try await task.value
        guides[providerID] = (Date(), programmes)
        return programmes
    }

    private static func fetch(providerID: String, sources: [URL]) async throws -> [String: [LiveProgramme]] {
        let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("epg-\(providerID).xml")
        if let attributes = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
           let modified = attributes[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < ttl,
           let data = try? Data(contentsOf: cacheURL) {
            let parsed = XMLTVParser.parse(data)
            if !parsed.isEmpty { return parsed }
        }
        var lastError: Error = URLError(.cannotLoadFromNetwork)
        for source in sources {
            do {
                var request = URLRequest(url: source, timeoutInterval: 30)
                request.setValue(M3UPlaylistLiveProvider.fetchUserAgent, forHTTPHeaderField: "User-Agent")
                let (raw, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw URLError(.badServerResponse)
                }
                guard let xml = raw.starts(with: [0x1f, 0x8b]) ? gunzip(raw) : raw else {
                    throw URLError(.cannotDecodeContentData)
                }
                let parsed = XMLTVParser.parse(xml)
                guard !parsed.isEmpty else { throw URLError(.cannotParseResponse) }
                try? xml.write(to: cacheURL, options: .atomic)
                return parsed
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Single-member gzip (RFC 1952) → raw DEFLATE via the Compression framework.
    static func gunzip(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        let count = bytes.count
        guard count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 {
            guard offset + 2 <= count else { return nil }
            offset += 2 + (Int(bytes[offset]) | Int(bytes[offset + 1]) << 8)
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {
            while offset < count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 }
        guard offset < count - 8 else { return nil }
        let size = Int(bytes[count - 4]) | Int(bytes[count - 3]) << 8
            | Int(bytes[count - 2]) << 16 | Int(bytes[count - 1]) << 24
        guard size > 0, size < 400_000_000 else { return nil }
        var output = [UInt8](repeating: 0, count: size)
        let written = bytes.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                compression_decode_buffer(
                    destination.baseAddress!, size,
                    source.baseAddress! + offset, count - 8 - offset,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        return written == size ? Data(output) : nil
    }
}

/// Streams an XMLTV document and keeps only programmes from now to +24h.
private final class XMLTVParser: NSObject, XMLParserDelegate {
    private var programmes: [String: [LiveProgramme]] = [:]
    private var channel: String?
    private var start: Date?
    private var stop: Date?
    private var title = ""
    private var inTitle = false
    private var hasTitle = false
    private let windowStart = Date().addingTimeInterval(-60 * 60)
    private let windowEnd = Date().addingTimeInterval(24 * 60 * 60)
    private let zoned = XMLTVParser.formatter("yyyyMMddHHmmss Z")
    private let plain = XMLTVParser.formatter("yyyyMMddHHmmss")

    static func parse(_ data: Data) -> [String: [LiveProgramme]] {
        let delegate = XMLTVParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.programmes.mapValues { $0.sorted { $0.start < $1.start } }
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter
    }

    private func date(_ value: String?) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return zoned.date(from: value) ?? plain.date(from: String(value.prefix(14)))
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "programme":
            channel = attributeDict["channel"]
            start = date(attributeDict["start"])
            stop = date(attributeDict["stop"])
            title = ""
            hasTitle = false
        case "title" where channel != nil && !hasTitle:
            inTitle = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inTitle { title += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        switch elementName {
        case "title" where inTitle:
            inTitle = false
            hasTitle = true
        case "programme":
            let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if let channel, let start, let stop, !name.isEmpty, stop > windowStart, start < windowEnd {
                programmes[channel, default: []].append(LiveProgramme(start: start, stop: stop, title: name))
            }
            channel = nil
        default:
            break
        }
    }
}
