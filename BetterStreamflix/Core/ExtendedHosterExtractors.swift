import Foundation
import CryptoKit
import CommonCrypto

/// Extended hoster extractors ported from BetterStreamflix Android (Apache-2.0).
///
/// `resolve` returns a playable `PlaybackSource` for every hoster that has a
/// dedicated extractor, or `nil` when the host is unknown so callers can fall
/// back to the generic page scanner. Host matching mirrors Android's
/// `Extractor.extract` dispatch: the URL host decides, with the provider's
/// server label as a hint.
enum ExtendedHosterExtractor {

    // MARK: - Dispatch

    static func resolve(
        _ url: URL,
        referer: URL?,
        serverName: String = "",
        depth: Int = 0
    ) async throws -> PlaybackSource? {
        guard depth < 3 else { return nil }
        let host = url.hostName?.lowercased() ?? ""
        let hint = serverName.lowercased()

        func matches(_ needles: [String]) -> Bool {
            needles.contains { host.contains($0) || hint.contains($0) }
        }

        if matches(["filemoon", "bf0skv", "bysejikuar", "bysezoxexe", "bysebuho",
               "bysekoze", "bysesayeveum", "moflix-stream"]) {
            return try await filemoon(url)
        }
        if matches(["supervideo", "superplayer"]) {
            return try await packed(url, referer: referer, providerID: "supervideo",
                                    filePattern: #"file\s*:\s*["']([^"']+)["']"#, refererOverride: "https://supervideo.cc")
        }
        if matches(["mixdrop", "mxdrop", "m1xdrop", "miiixdrop", "miixdrop", "dropstream"]) {
            return try await mixdrop(url, referer: referer)
        }
        if matches(["dropload", "dr0pstream"]) {
            return try await packed(url, referer: referer, providerID: "dropload",
                                    filePattern: #"file\s*:\s*["']([^"']+)["']"#, useFinalURLReferer: true)
        }
        if matches(["fsvid"]) {
            return try await packed(url, referer: referer, providerID: "fsvid",
                                    filePattern: #"src\s*:\s*["']([^"']+)["']"#)
        }
        if matches(["streamhub"]) {
            let embed = URL(string: url.absoluteString.replacingOccurrences(of: "/d/", with: "/e/")) ?? url
            return try await packed(embed, referer: referer ?? embed, providerID: "streamhub",
                                    filePattern: #"src\s*:\s*["']([^"']+)["']"#)
        }
        if matches(["streamruby"]) {
            return try await packed(url, referer: referer, providerID: "streamruby",
                                    filePattern: #"file\s*:\s*["']([^"']+)["']"#)
        }
        if matches(["luluvdo", "lulustream", "luluvdoo"]) {
            return try await packed(url, referer: referer, providerID: "luluvdo",
                                    filePattern: #"file\s*:\s*["']([^"']+)["']"#)
        }
        if matches(["2embed"]) {
            return try await NetPrimeEmbeds.twoEmbed(url, depth: depth)
        }
        if matches(["uqload"]) {
            return try await packed(url, referer: referer, providerID: "uqload",
                                    filePattern: #"file\s*:\s*["']([^"']+)["']"#, refererOverride: url.origin + "/")
        }
        if matches(["ups2up", "up4stream", "up4fun"]) {
            return try await packed(url, referer: referer, providerID: "ustr",
                                    filePattern: #"file\s*:\s*["']([^"']+)["']"#)
        }
        if matches(["vidzy"]) {
            return try await packed(url, referer: referer, providerID: "vidzy",
                                    filePattern: #"src\s*:\s*["']([^"']+)["']"#, loadTracksSubs: true)
        }
        if matches(streamWishHosts) || hint.contains("streamwish") || hint.contains("wish") {
            return try await streamWish(url, referer: referer)
        }
        if matches(["vidmoly"]) {
            return try await vidmoly(url)
        }
        if matches(["vtbe", "vtube"]) {
            return try await vtube(url, referer: referer)
        }
        if matches(["bigwarp"]) {
            return try await jwPlayer(url, referer: referer, refererOverride: "https://bigwarp.cc/")
        }
        if matches(["oneupload", "tipfly"]) {
            return try await jwPlayer(url, referer: referer, refererOverride: url.origin + "/")
        }
        if matches(["yourupload", "yucache"]) {
            return try await jwPlayer(url, referer: referer, refererOverride: "https://www.yourupload.com")
        }
        if matches(["savefiles"]) {
            return try await savefiles(url)
        }
        if matches(["gupload"]) {
            return try await gupload(url, referer: referer)
        }
        if matches(["ridoo"]) {
            return try await ridoo(url, referer: referer)
        }
        if matches(["vidply"]) {
            return try await vidply(url)
        }
        if matches(["dhtpre", "filelions", "vidhide", "vidhidepro", "moflix-upns"]) {
            return try await vidhide(url, referer: referer)
        }
        if matches(["loadx"]) {
            return try await loadx(url)
        }
        if matches(["strmup", "streamup"]) {
            return try await streamUp(url)
        }
        if matches(["pluspomla"]) {
            return try await plusPomla(url, referer: referer)
        }
        if matches(["dailymotion", "dmcdn", "dai.ly"]) {
            return try await dailymotion(url, referer: referer)
        }
        if matches(["ok.ru", "odnoklassniki", "mycdn.me"]) {
            return try await okru(url, referer: referer)
        }
        if matches(["veev", "kinoger.pw", "poophq", "doods"]) {
            return try await veev(url, referer: referer)
        }
        if matches(["rpmvid", "cubeembed", "upns", "loadm.cam", "playerp2p",
               "rpmstream", "strp2p", "rpmplay", "flix2day", "primevid", "anibum", "flemmix", "moflix."]) {
            return try await rpmvid(url)
        }
        if matches(["magasavor"]) {
            return try await magasavor(url, referer: referer)
        }
        if matches(["vidguard", "vguard", "vembed.net", "vgtembed", "listeamed", "bembed", "vid-guard"]) {
            return try await vidguard(url, referer: referer)
        }
        if matches(["closeload", "ridorapid"]) {
            return try await closeload(url, referer: referer)
        }
        if matches(["chillx", "jeansaispasplus"]) {
            return try await chillx(url, referer: referer)
        }
        if matches(["upzone"]) {
            return try await upzone(url, referer: referer, depth: depth)
        }
        if matches(["nupload", "nupupload"]) {
            return try await nuupload(url, referer: referer, depth: depth)
        }
        if matches(["megaup", "goodstream"]) {
            return try await jwPlayer(url, referer: referer, refererOverride: url.origin + "/")
        }
        return nil
    }

    // MARK: - Shared helpers

    private static var http: HosterHTTP { .shared }
    private static let desktopUA = HTTPClient.desktopUserAgent

    private static func headers(referer: String?, origin: String? = nil, extra: [String: String] = [:]) -> [String: String] {
        var result = ["User-Agent": desktopUA]
        if let referer { result["Referer"] = referer }
        if let origin { result["Origin"] = origin }
        for (key, value) in extra { result[key] = value }
        return result
    }

    private static func unpackedScripts(in html: String) -> [String] {
        HosterResolver.scriptBodies(in: html).compactMap { JSPacker.unpack($0) }
    }

    private static func haystacks(in html: String) -> [String] {
        [html] + unpackedScripts(in: html)
    }

    /// `file:` / `src:` / `hlsN` player patterns most packed players expose.
    private static let commonSourcePatterns = [
        #"file\s*:\s*["']([^"']+)["']"#,
        #"src\s*:\s*["']([^"']+)["']"#,
        #"["'](hls\d*)["']\s*:\s*["']([^"']+\.m3u8[^"']*)["']"#,
        #"["'](?:file|src|source|videoUrl|url)["']\s*[:=]\s*["']((?:https?://|/)[^"']+\.(?:m3u8|mp4)[^"']*)["']"#,
        #"sources?\s*[:=]\s*\[\s*["']((?:https?://|/)[^"']+\.(?:m3u8|mp4)[^"']*)["']"#,
        #"(https?://[^"'\s\\<]+\.m3u8[^"'\s\\<]*)"#,
    ]

    private static func firstSource(in texts: [String], patterns: [String], relativeTo base: URL) -> URL? {
        for text in texts {
            let normalized = text.replacingOccurrences(of: "\\/", with: "/")
            for pattern in patterns {
                for match in AnimeHTML.captures(pattern, in: normalized) {
                    let raw = match.count > 2 && pattern.contains("hls") ? match[2] : match[1]
                    guard !raw.isEmpty else { continue }
                    if let resolved = ProviderNetwork.absolute(raw, relativeTo: base) { return resolved }
                }
            }
        }
        return nil
    }

    private static func captions(in unpacked: String, providerID: String, providerName: String, base: URL) -> [SubtitleSource] {
        let tracks = AnimeHTML.captures(#"tracks\s*:\s*\[([\s\S]*?)\]"#, in: unpacked).first?[1] ?? ""
        let pattern = #"file\s*:\s*"(.*?)"\s*,?\s*label\s*:\s*"(.*?)"\s*,?\s*kind\s*:\s*"captions""#
        return AnimeHTML.captures(pattern, in: tracks).compactMap { match -> SubtitleSource? in
            let file = match[1], label = match[2]
            guard !label.contains("Upload"), let url = ProviderNetwork.absolute(file, relativeTo: base) else { return nil }
            return SubtitleSource(
                providerID: providerID,
                providerName: providerName,
                label: label,
                languageCode: AnimeStreamResolver.languageCode(label),
                url: url
            )
        }
    }

    // MARK: - Packed `file:`/`src:` family

    /// Supervideo / Dropload / Fsvid / StreamHub / Streamruby / LuluVdo /
    /// Uqload / USTR / Vidzy all hide their player config in a packed eval
    /// block. One implementation covers them, parameterised by the file regex.
    private static func packed(
        _ url: URL,
        referer: URL?,
        providerID: String,
        filePattern: String,
        refererOverride: String? = nil,
        useFinalURLReferer: Bool = false,
        loadTracksSubs: Bool = false
    ) async throws -> PlaybackSource {
        let response = try await http.get(url, referer: referer)
        let html = response.text
        let finalPage = response.url
        let texts = unpackedScripts(in: html) + [html]
        var patterns = [filePattern]
        patterns.append(contentsOf: commonSourcePatterns.dropFirst(2))
        guard let source = firstSource(in: texts, patterns: patterns, relativeTo: finalPage) else {
            throw AppError.noStream
        }
        let refererValue = useFinalURLReferer ? finalPage.origin : (refererOverride ?? url.origin)
        let unpacked = unpackedScripts(in: html).joined(separator: "\n")
        var subs = captions(in: unpacked, providerID: providerID, providerName: providerID.capitalized, base: finalPage)
        if loadTracksSubs {
            subs.append(contentsOf: vidzyTracks(in: unpacked, base: finalPage))
        }
        return PlaybackSource(
            url: source,
            headers: headers(referer: refererValue, origin: finalPage.origin),
            subtitles: subs,
            preferredPeakBitRate: nil
        )
    }

    private static func vidzyTracks(in unpacked: String, base: URL) -> [SubtitleSource] {
        guard let block = AnimeHTML.captures(#"loadTracks\s*\(\s*\[([\s\S]*?)\]\s*\)"#, in: unpacked).first?[1] else { return [] }
        return AnimeHTML.captures(#"\{([\s\S]*?)\}"#, in: block).compactMap { match -> SubtitleSource? in
            let body = match[1]
            guard let label = AnimeHTML.captures(#"label\s*:\s*'([^']+)'"#, in: body).first?[1],
                  let file = AnimeHTML.captures(#"src\s*:\s*'([^']+)'"#, in: body).first?[1],
                  let url = ProviderNetwork.absolute(file, relativeTo: base) else { return nil }
            return SubtitleSource(
                providerID: "vidzy",
                providerName: "Vidzy",
                label: label,
                languageCode: AnimeStreamResolver.languageCode(label),
                url: url
            )
        }
    }

    // MARK: - StreamWish family

    /// ~70 rotating domains of the streamwish player (uqloads, swishsrv,
    /// hlswish, playerwish, swiftplayers, embedwish, wishembed, ...).
    private static let streamWishHosts = [
        "streamwish", "ajmidyad", "khadhnayad", "yadmalik", "hayaatieadhab",
        "kharabnahs", "atabkhha", "atabknha", "atabknhk", "atabknhs", "abkrzkr",
        "abkrzkz", "wishembed", "mwish", "strmwis", "awish", "dwish", "vidmoviesb",
        "embedwish", "cilootv", "uqloads", "tuktukcinema", "ankrzkz", "volvovideo",
        "wishfast", "ankrznm", "sfastwish", "eghjrutf", "eghzrutw", "playembed",
        "egsyxurh", "egtpgrvh", "flaswish", "obeywish", "cdnwish", "javsw",
        "cinemathek", "trgsfjll", "fsdcmo", "anime4low", "mohahhda", "ma2d",
        "dancima", "swhoi", "gsfqzmqu", "jodwish", "swdyu", "strwish", "asnwish",
        "wishonly", "playerwish", "katomen", "swishsrv", "iplayerhls", "hlsflast",
        "4yftwvrdz7", "ghbrisk", "cybervynx", "stbhg", "dhcplay", "gradehgplus",
        "ultpreplayer", "hglink", "haxloppd", "swish", "wishon", "vidwish",
        "hanerix", "hlswish", "swiftplayers", "eb8gfmjn71", "edbrdl7pab",
        "kinoger.be", "voe.sx", "wish",
    ]

    /// MixDrop family: `/f/` share links become `/e/` embeds; the unpacked eval
    /// block exposes the MP4 as `wurl = "…"` (often protocol-relative).
    private static func mixdrop(_ link: URL, referer: URL?) async throws -> PlaybackSource {
        var raw = link.absoluteString
            .replacingOccurrences(of: "/f/", with: "/e/")
            .replacingOccurrences(of: ".club/", with: ".ag/")
        if let range = raw.range(of: #"(?i)^(https?://[^/]+/e/[^/?#]+)"#, options: .regularExpression) {
            raw = String(raw[range])
        }
        guard let embedURL = URL(string: raw) else { throw AppError.noStream }
        let html = try await http.page(embedURL, referer: referer ?? embedURL)
        let texts = unpackedScripts(in: html) + [html]
        for text in texts {
            guard let wurl = AnimeHTML.captures(#"wurl.*?=.*?"(.*?)";"#, in: text).first?[1] else { continue }
            let full: String
            if wurl.hasPrefix("//") {
                full = "https:" + wurl
            } else if wurl.hasPrefix("http") {
                full = wurl
            } else {
                full = "https://" + wurl
            }
            guard let source = URL(string: full) else { continue }
            return PlaybackSource(
                url: source,
                headers: headers(referer: link.absoluteString, origin: embedURL.origin),
                subtitles: [],
                preferredPeakBitRate: nil
            )
        }
        throw AppError.noStream
    }

    private static func streamWish(_ url: URL, referer: URL?) async throws -> PlaybackSource {
        let html = try await http.page(url, referer: referer ?? url)
        let texts = unpackedScripts(in: html) + [html]
        let pattern = #"(?:["']?hls(\d*)["']?|["']?file["']?)\s*[:=]\s*["']((?:https?://|/)[^"']+\.m3u8[^"']*)["']"#
        var best: (rank: Int, url: URL)?
        for text in texts {
            for match in AnimeHTML.captures(pattern, in: text) {
                let rank = Int(match[1]) ?? 0
                guard let resolved = ProviderNetwork.absolute(match[2], relativeTo: url) else { continue }
                if best == nil || rank > best!.rank { best = (rank, resolved) }
            }
        }
        guard let source = best?.url else { throw AppError.noStream }
        let unpacked = texts.joined(separator: "\n")
        return PlaybackSource(
            url: source,
            headers: headers(
                referer: url.origin + "/",
                origin: url.origin,
                extra: ["Accept": "*/*", "Accept-Language": "en-US,en;q=0.5"]
            ),
            subtitles: captions(in: unpacked, providerID: "streamwish", providerName: "StreamWish", base: url),
            preferredPeakBitRate: nil
        )
    }

    // MARK: - Regex-in-page family

    private static func vidmoly(_ url: URL) async throws -> PlaybackSource {
        // vidmoly.me pages only resolve on the .to host.
        let target = URL(string: url.absoluteString.replacingOccurrences(of: ".me/", with: ".to/")) ?? url
        let html = try await http.page(target, referer: URL(string: "https://vidmoly.to/"))
        guard let match = AnimeHTML.captures(
            #"sources\s*:\s*\[\s*\{\s*file\s*:\s*['"]([^'"]+)['"]"#, in: html
        ).first ?? AnimeHTML.captures(#"file\s*:\s*['"]([^'"]+\.m3u8[^'"]*)['"]"#, in: html).first,
              let source = ProviderNetwork.absolute(match[1], relativeTo: target) else { throw AppError.noStream }
        return PlaybackSource(
            url: source,
            headers: headers(referer: "https://vidmoly.to/"),
            subtitles: [],
            preferredPeakBitRate: nil
        )
    }

    private static func vtube(_ url: URL, referer: URL?) async throws -> PlaybackSource {
        let html = try await http.page(url, referer: referer ?? url)
        guard let match = AnimeHTML.captures(#"sources\s*:\s*\[\s*\{file:"([^"]+\.m3u8[^"]*)""#, in: html).first
                ?? AnimeHTML.captures(#"file\s*:\s*"([^"]+\.m3u8[^"]*)""#, in: html).first,
              let source = ProviderNetwork.absolute(match[1], relativeTo: url) else { throw AppError.noStream }
        return PlaybackSource(
            url: source,
            headers: headers(referer: url.origin + "/", origin: url.origin),
            subtitles: [],
            preferredPeakBitRate: nil
        )
    }

    /// BigWarp / OneUpload / YourUpload / Goodstream: the JWPlayer config sits
    /// un-packed in a `script[type*=javascript]` block.
    private static func jwPlayer(_ url: URL, referer: URL?, refererOverride: String) async throws -> PlaybackSource {
        let html = try await http.page(url, referer: referer)
        for script in HosterResolver.scriptBodies(in: html) + [html] {
            guard script.contains("jwplayer") || script.contains("sources") || script.contains("file") else { continue }
            if let match = AnimeHTML.captures(#"file\s*:\s*["']([^"']+)["']"#, in: script).first,
               let source = ProviderNetwork.absolute(match[1], relativeTo: url) {
                return PlaybackSource(
                    url: source,
                    headers: headers(referer: refererOverride),
                    subtitles: [],
                    preferredPeakBitRate: nil
                )
            }
        }
        throw AppError.noStream
    }

    private static func savefiles(_ url: URL) async throws -> PlaybackSource {
        let fileCode = url.path.split(separator: "/").last.map(String.init)?.components(separatedBy: "?").first ?? ""
        guard !fileCode.isEmpty else { throw AppError.noStream }
        let base = url.origin
        guard let dl = URL(string: base + "/dl?op=embed&file_code=\(fileCode)&auto=0&referer=") else { throw AppError.invalidURL }
        let html = try await http.page(dl, referer: url)
        for script in HosterResolver.scriptBodies(in: html) {
            guard script.contains("jwplayer"), script.contains("sources"), script.contains("file") else { continue }
            if let match = AnimeHTML.captures(#"file\s*:\s*["']([^"']+)["']"#, in: script).first,
               let source = ProviderNetwork.absolute(match[1], relativeTo: dl) {
                return PlaybackSource(url: source, headers: headers(referer: base + "/"), subtitles: [], preferredPeakBitRate: nil)
            }
        }
        throw AppError.noStream
    }

    private static func gupload(_ url: URL, referer: URL?) async throws -> PlaybackSource {
        let html = try await http.page(url, referer: referer)
        // Modern players ship a `const config = {...}` object literal.
        for marker in ["const config", "var config", "let config"] {
            if let json = objectLiteral(after: marker, in: html),
               let data = json.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let raw = object["videoUrl"] as? String, !raw.isEmpty,
               let source = ProviderNetwork.absolute(raw, relativeTo: url) {
                return PlaybackSource(
                    url: source,
                    headers: headers(referer: url.origin),
                    subtitles: [],
                    preferredPeakBitRate: nil
                )
            }
        }
        // Legacy pages pack everything.
        if let source = firstSource(in: unpackedScripts(in: html) + [html], patterns: commonSourcePatterns, relativeTo: url) {
            return PlaybackSource(url: source, headers: headers(referer: url.origin), subtitles: [], preferredPeakBitRate: nil)
        }
        throw AppError.noStream
    }

    /// Balanced-brace object literal right after a marker like `const config =`.
    private static func objectLiteral(after marker: String, in text: String) -> String? {
        guard let range = text.range(of: marker) else { return nil }
        var rest = text[range.upperBound...]
        guard let eq = rest.firstIndex(of: "=") else { return nil }
        rest = rest[rest.index(after: eq)...]
        guard let start = rest.firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = start
        while index < rest.endIndex {
            let character = rest[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 { return String(rest[start...index]) }
            }
            index = rest.index(after: index)
        }
        return nil
    }

    private static func ridoo(_ url: URL, referer: URL?) async throws -> PlaybackSource {
        let html = try await http.page(url, referer: referer ?? url)
        guard let match = AnimeHTML.captures(#"file\s*:\s*"([^"]+\.m3u8[^"]*)""#, in: html).first,
              let source = ProviderNetwork.absolute(match[1], relativeTo: url) else { throw AppError.noStream }
        return PlaybackSource(url: source, headers: headers(referer: url.origin + "/"), subtitles: [], preferredPeakBitRate: nil)
    }

    /// VidPly: DoodStream-style `/e/` page whose `$.get('/pass_md5/...')`
    /// endpoint returns the URL prefix; the player JS adds `?token=`.
    private static func vidply(_ url: URL) async throws -> PlaybackSource {
        let embed = URL(string: url.absoluteString.replacingOccurrences(of: "/d/", with: "/e/")) ?? url
        let html = try await http.page(embed, referer: embed)
        guard let path = AnimeHTML.captures(#"\$\.get\('(/pass_md5/[^']+)'"#, in: html).first?[1],
              let pass = URL(string: embed.origin + path) else { throw AppError.noStream }
        let base = try await http.page(pass, referer: embed).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { throw AppError.noStream }
        let token = AnimeHTML.captures(#"return\s*[^?]+\?token=([^&]+)&expiry="#, in: html).first?[1] ?? ""
        guard let source = URL(string: base + "?token=" + token) else { throw AppError.noStream }
        return PlaybackSource(url: source, headers: headers(referer: embed.origin + "/"), subtitles: [], preferredPeakBitRate: nil)
    }

    /// VidHide (dhtpre / filelions): packed player exposes `hls2`/`hls4`.
    private static func vidhide(_ url: URL, referer: URL?) async throws -> PlaybackSource {
        let html = try await http.page(url, referer: referer ?? url)
        var links: [String: String] = [:]
        for text in unpackedScripts(in: html) + [html] {
            for match in AnimeHTML.captures(#"["'](hls\d+)["']\s*:\s*["'](.*?)["']"#, in: text) {
                links[match[1]] = match[2]
            }
        }
        guard let raw = links["hls4"] ?? links["hls2"],
              let source = ProviderNetwork.absolute(raw, relativeTo: url) else { throw AppError.noStream }
        return PlaybackSource(url: source, headers: headers(referer: url.origin + "/"), subtitles: [], preferredPeakBitRate: nil)
    }

    // MARK: - API-backed extractors

    /// LoadX: the page sets a `fireplayer_player` cookie which the
    /// `player/index.php?do=getVideo` ajax endpoint requires.
    private static func loadx(_ url: URL) async throws -> PlaybackSource {
        let firefoxUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:139.0) Gecko/20100101 Firefox/139.0"
        let response = try await http.get(url, headers: ["User-Agent": firefoxUA])
        guard (200..<400).contains(response.statusCode) else { throw AppError.noStream }
        guard let cookie = response.cookie(named: "fireplayer_player").map({ "fireplayer_player=\($0)" })
                ?? response.cookieHeader else { throw AppError.noStream }
        let videoID = url.path.split(separator: "/").last.map(String.init) ?? ""
        guard !videoID.isEmpty, let api = URL(string: url.origin + "/player/index.php?data=\(videoID)&do=getVideo") else {
            throw AppError.noStream
        }
        let request = HosterHTTP.formRequest(url: api, referer: url, fields: [:])
        var withCookie = request
        withCookie.setValue(cookie, forHTTPHeaderField: "Cookie")
        withCookie.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        let apiResponse = try await http.send(withCookie)
        guard let object = try? JSONSerialization.jsonObject(with: apiResponse.data) as? [String: Any],
              let raw = object["videoSource"] as? String, !raw.isEmpty,
              let source = URL(string: raw) else { throw AppError.noStream }
        return PlaybackSource(
            url: source,
            headers: headers(referer: "https://loadx.ws", origin: "https://loadx.ws",
                             extra: ["Cookie": cookie, "Accept": "*/*"]),
            subtitles: [],
            preferredPeakBitRate: nil
        )
    }

    /// StreamUp (strmup.to): `ajax/stream?filecode=` returns the manifest JSON.
    private static func streamUp(_ url: URL) async throws -> PlaybackSource {
        let fileCode = url.path.split(separator: "/").last.map(String.init) ?? ""
        guard !fileCode.isEmpty else { throw AppError.noStream }
        guard let api = URL(string: "https://strmup.to/ajax/stream?filecode=\(fileCode)") else { throw AppError.invalidURL }
        let object = try await http.jsonObject(api, referer: URL(string: "https://strmup.to/v/\(fileCode)"))
        guard let raw = object["streaming_url"] as? String, !raw.isEmpty,
              let source = URL(string: raw) else { throw AppError.noStream }
        let subs = (object["subtitles"] as? [[String: Any]] ?? []).compactMap { item -> SubtitleSource? in
            guard let file = item["file_path"] as? String, let sub = URL(string: file) else { return nil }
            let label = item["language"] as? String ?? "Subtitle"
            return SubtitleSource(providerID: "streamup", providerName: "StreamUp",
                                  label: label, languageCode: AnimeStreamResolver.languageCode(label), url: sub)
        }
        return PlaybackSource(url: source, headers: headers(referer: "https://strmup.to/"), subtitles: subs, preferredPeakBitRate: nil)
    }

    /// PlusPomla: the page AJAXes a JSON that carries `sources[].file`.
    private static func plusPomla(_ url: URL, referer: URL?) async throws -> PlaybackSource {
        let html = try await http.page(url, referer: referer)
        guard let raw = AnimeHTML.captures(#"\$\.ajax\s*\(\s*\{\s*url\s*:\s*["']([^"']+)["']"#, in: html).first?[1] else {
            throw AppError.noStream
        }
        let endpoint = raw.hasPrefix("//") ? "https:" + raw : raw
        guard let api = ProviderNetwork.absolute(endpoint, relativeTo: url) else { throw AppError.noStream }
        let object = try await http.json(api, referer: url)
        var sources: [String] = []
        if let list = object as? [String: Any] {
            for item in (list["sources"] as? [[String: Any]] ?? []) {
                if let file = item["file"] as? String, !file.isEmpty { sources.append(file) }
            }
        } else if let list = object as? [[String: Any]] {
            sources = list.compactMap { $0["file"] as? String }.filter { !$0.isEmpty }
        }
        guard let first = sources.first, let source = ProviderNetwork.absolute(first, relativeTo: api) else {
            throw AppError.noStream
        }
        return PlaybackSource(url: source, headers: headers(referer: url.absoluteString), subtitles: [], preferredPeakBitRate: nil)
    }

    /// Dailymotion: `player/metadata/video/<id>` exposes `qualities.auto[0].url`.
    private static func dailymotion(_ url: URL, referer: URL?) async throws -> PlaybackSource {
        let id = url.path.split(separator: "/").last.map(String.init)
            ?? URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "video" })?.value
            ?? ""
        guard !id.isEmpty else { throw AppError.noStream }
        let viewID = String((0..<19).compactMap { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement() })
        guard let api = URL(string: "https://www.dailymotion.com/player/metadata/video/\(id)?locale=en&v1st=\(UUID().uuidString)&ts=\(Int(Date().timeIntervalSince1970))&viewId=\(viewID)") else {
            throw AppError.invalidURL
        }
        let object = try await http.jsonObject(api, referer: URL(string: "https://www.dailymotion.com/player/xtv3w.html"))
        guard let qualities = object["qualities"] as? [String: Any],
              let auto = qualities["auto"] as? [[String: Any]],
              let raw = auto.first?["url"] as? String,
              let source = URL(string: raw) else { throw AppError.noStream }
        return PlaybackSource(url: source, headers: headers(referer: "https://www.dailymotion.com"), subtitles: [], preferredPeakBitRate: nil)
    }

    /// Ok.ru: `div[data-options]` JSON → flashvars.metadata → hlsManifestUrl or
    /// the ranked `videos` list.
    private static func okru(_ url: URL, referer: URL?) async throws -> PlaybackSource {
        let html = try await http.page(url, referer: referer)
        guard let rawOptions = AnimeHTML.captures(#"data-options="([^"]+)"#, in: html).first?[1] else { throw AppError.noStream }
        let optionsText = HTMLPayloadParser.decodeEntities(rawOptions)
        guard let data = optionsText.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AppError.noStream }
        let flashvars = root["flashvars"] as? [String: Any] ?? root
        var metadata: [String: Any]?
        if let object = flashvars["metadata"] as? [String: Any] {
            metadata = object
        } else if let raw = flashvars["metadata"] as? String, !raw.isEmpty,
                  let rawData = raw.data(using: .utf8) {
            metadata = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any]
        }
        guard let metadata else { throw AppError.noStream }
        if let hls = metadata["hlsManifestUrl"] as? String, hls.hasPrefix("http"), let source = URL(string: hls) {
            return PlaybackSource(url: source, headers: headers(referer: "https://ok.ru"), subtitles: [], preferredPeakBitRate: nil)
        }
        let videos = metadata["videos"] as? [[String: Any]] ?? []
        var byName: [String: String] = [:]
        for item in videos {
            guard let name = item["name"] as? String, !name.isEmpty,
                  let videoURL = item["url"] as? String else { continue }
            let cleaned = videoURL.replacingOccurrences(of: "\\u0026", with: "&")
            if cleaned.hasPrefix("http") { byName[name] = cleaned }
        }
        for key in ["full", "hd", "sd", "low", "lowest", "mobile", "quad", "ultra"] {
            if let raw = byName[key], let source = URL(string: raw) {
                return PlaybackSource(url: source, headers: headers(referer: "https://ok.ru"), subtitles: [], preferredPeakBitRate: nil)
            }
        }
        // Legacy escaped list: "videos":[{"name":"mobile","url":"..."}] inside the
        // data-options blob itself.
        if let raw = AnimeHTML.captures(#""(https?://[^"']+\.(?:m3u8|mp4)[^"']*)""#, in: optionsText).first?[1],
           let source = URL(string: raw) {
            return PlaybackSource(url: source, headers: headers(referer: "https://ok.ru"), subtitles: [], preferredPeakBitRate: nil)
        }
        throw AppError.noStream
    }

    // MARK: - Crypto extractors

    /// Veev (veev.to / kinoger.pw / poophq / doods): the `/e/` page carries
    /// `fc`/`_vvto[]` LZW-packed params used by the `dl?op=player_api` call,
    /// whose response stream is itself LZW-packed plus transform-array encoded.
    private static func veev(_ url: URL, referer: URL?) async throws -> PlaybackSource {
        guard let match = AnimeHTML.captures(
            #"(?://|\.)((?:veev|kinoger|poophq|doods)\.(?:to|pw|com))/(?:e|d)/([0-9a-zA-Z]+)"#,
            in: url.absoluteString
        ).first else { throw AppError.noStream }
        let host = match[1]
        var mediaID = match[2]
        let webURL = URL(string: "https://\(host)/e/\(mediaID)")!
        let fallbackReferer = referer ?? url
        let response = try await http.get(webURL, referer: fallbackReferer,
                                          headers: ["User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:109.0) Gecko/20100101 Firefox/115.0"])
        if let reMatch = AnimeHTML.captures(#"(?:e|d)/([0-9a-zA-Z]+)"#, in: response.url.absoluteString).first,
           reMatch[1] != mediaID {
            mediaID = reMatch[1]
        }
        let body = response.text
        let items = AnimeHTML.captures(#"[\.\s'](?:fc|_vvto\[[^\]]*)(?:['\]]*)?\s*[:=]\s*['"]([^'"]+)"#, in: body).map { $0[1] }
        guard !items.isEmpty else { throw AppError.noStream }
        for raw in items.reversed() {
            let ch = veevDecode(raw)
            guard ch != raw else { continue }
            let mainLink = "https://\(host)"
            let refererValue = fallbackReferer.absoluteString
            guard var components = URLComponents(string: mainLink + "/dl") else { continue }
            components.queryItems = [
                URLQueryItem(name: "op", value: "player_api"),
                URLQueryItem(name: "cmd", value: "gi"),
                URLQueryItem(name: "file_code", value: mediaID),
                URLQueryItem(name: "r", value: refererValue),
                URLQueryItem(name: "ch", value: ch),
                URLQueryItem(name: "ie", value: "1"),
            ]
            guard let api = components.url else { continue }
            guard let json = try? await http.jsonObject(api, referer: webURL,
                                                        headers: ["User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:109.0) Gecko/20100101 Firefox/115.0",
                                                                  "Origin": mainLink]),
                  let file = json["file"] as? [String: Any],
                  (file["file_status"] as? String) == "OK",
                  let dv = (file["dv"] as? [[String: Any]])?.first?["s"] as? String else { continue }
            let decoded = veevDecode(dv)
            guard let transform = veevBuildArray(ch).first,
                  let sourceURL = URL(string: veevDecodeURL(decoded, transform: transform)) else { continue }
            return PlaybackSource(
                url: sourceURL,
                headers: headers(referer: refererValue, origin: refererValue),
                subtitles: [],
                preferredPeakBitRate: nil
            )
        }
        throw AppError.noStream
    }

    /// Veev's LZW-flavoured `uncl` decompressor.
    private static func veevDecode(_ text: String) -> String {
        guard let first = text.first else { return text }
        var result = String(first)
        var lut: [Int: String] = [:]
        var n = 256
        var c = first
        for char in text.dropFirst() {
            let code = Int(char.unicodeScalars.first?.value ?? 0)
            let nc: String
            if code < 256 { nc = String(char) } else { nc = lut[code] ?? (String(c) + String(c)) }
            result += nc
            lut[n] = String(c) + String(nc.first ?? c)
            n += 1
            c = nc.first ?? c
        }
        return result
    }

    private static func veevBuildArray(_ encoded: String) -> [[Int]] {
        var chars = Array(encoded)
        var result: [[Int]] = []
        func jsInt(_ c: Character) -> Int { c.isNumber ? Int(String(c)) ?? 0 : 0 }
        var count = chars.isEmpty ? 0 : jsInt(chars.removeFirst())
        while count != 0, !chars.isEmpty {
            var current: [Int] = []
            for _ in 0..<count {
                guard !chars.isEmpty else { break }
                current.insert(jsInt(chars.removeFirst()), at: 0)
            }
            result.append(current)
            count = chars.isEmpty ? 0 : jsInt(chars.removeFirst())
        }
        return result
    }

    private static func veevDecodeURL(_ etext: String, transform: [Int]) -> String {
        var ds = etext
        for t in transform {
            if t == 1 { ds = String(ds.reversed()) }
            var bytes: [UInt8] = []
            var index = ds.startIndex
            while index < ds.endIndex {
                let next = ds.index(index, offsetBy: 2, limitedBy: ds.endIndex) ?? ds.endIndex
                let pair = String(ds[index..<next])
                if let byte = UInt8(pair, radix: 16) { bytes.append(byte) }
                index = next
            }
            ds = String(decoding: bytes, as: UTF8.self)
            ds = ds.replacingOccurrences(of: "dXRmOA==", with: "")
        }
        return ds
    }

    // MARK: - Correction helpers

    /// Rpmvid family (rpmvid / cubeembed / upns / playerp2p / ...): the
    /// `/api/v1/video` response is a hex-encoded AES-CBC payload; the JSON then
    /// prefers `source` > `cfNative` > `hls`.
    private static func rpmvid(_ url: URL) async throws -> PlaybackSource {
        guard let fragmentID = url.fragment ?? url.path.split(separator: "#").last.map(String.init) else {
            // Links look like https://host/embed/#<id>
            guard let tail = url.absoluteString.split(separator: "#").last.map(String.init) else { throw AppError.noStream }
            return try await rpmvidResolve(id: tail, origin: url.origin)
        }
        return try await rpmvidResolve(id: fragmentID, origin: url.origin)
    }

    private static func rpmvidResolve(id: String, origin: String) async throws -> PlaybackSource {
        guard let api = URL(string: "\(origin)/api/v1/video?id=\(id)&w=1920&h=1080") else { throw AppError.invalidURL }
        let response = try await http.get(api, referer: URL(string: origin))
        let hex = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let decrypted = ExtendedCrypto.aesCBCDecryptHex(hex, key: Array("kiemtienmua911ca".utf8), iv: Array("1234567890oiuytr".utf8)),
              let data = decrypted.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AppError.noStream }
        func string(_ key: String) -> String? {
            guard let value = json[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        var candidates: [String] = []
        if let source = string("source") { candidates.append(source) }
        if let cfNative = string("cfNative") { candidates.append(cfNative) }
        if let hls = string("hls") { candidates.append(origin + hls) }
        if var cf = string("cf"), !cf.contains("skyforgeconcepts.shop") {
            if let pk = json["pk"] as? [String: Any],
               let k = pk["k"] as? String, let kx = pk["kx"] as? String, !k.isEmpty, !kx.isEmpty {
                cf += "?k=\(k)&kx=\(kx)"
            } else if let cfExpire = string("cfExpire") {
                let parts = cfExpire.split(separator: ":")
                if parts.count >= 2 { cf += "?t=\(parts[0])&e=\(parts[1])" }
            }
            candidates.append(cf)
        }
        for raw in candidates {
            guard let source = ProviderNetwork.absolute(raw, relativeTo: URL(string: origin)) else { continue }
            return PlaybackSource(url: source, headers: headers(referer: origin), subtitles: [], preferredPeakBitRate: nil)
        }
        throw AppError.noStream
    }

    /// MagaSavor: VOE-style `application/json` script with the F7 payload.
    private static func magasavor(_ url: URL, referer: URL?) async throws -> PlaybackSource {
        let html = try await http.page(url, referer: referer)
        var encoded: [String] = AnimeHTML
            .captures(#"<script[^>]+type=["']application/json["'][^>]*>([\s\S]*?)</script>"#, in: html)
            .map { $0[1].trimmingCharacters(in: CharacterSet(charactersIn: "[]\"' \n\t")) }
        if let regexEncoded = AnimeHTML.captures(#"MGGIYVAAHEDNVNIPRTAPRPAAVVRSAARHI==#\.?[\s\S]*?['"]([A-Za-z0-9+/=_@~%*#!^&?-]+)['"]"#, in: html).first?[1] {
            encoded.append(regexEncoded)
        }
        for candidate in encoded {
            guard let payload = VoeCrypto.decrypt(candidate),
                  let raw = payload["source"] as? String, !raw.isEmpty,
                  let source = ProviderNetwork.absolute(raw, relativeTo: url) else { continue }
            return PlaybackSource(
                url: source,
                headers: headers(referer: url.origin + "/", origin: url.origin),
                subtitles: [],
                preferredPeakBitRate: nil
            )
        }
        throw AppError.noStream
    }

    /// VidGuard: packed script exposes `window.svg={"stream":"..."}`; the
    /// `sig` query param is hex-xor-2 → base64 → trim → reverse → swap pairs.
    private static func vidguard(_ url: URL, referer: URL?) async throws -> PlaybackSource {
        let html = try await http.page(url, referer: referer)
        for text in unpackedScripts(in: html) + [html] {
            guard let encoded = AnimeHTML.captures(#"window\.svg=\{"stream":"([^"]+)""#, in: text).first?[1],
                  let source = URL(string: vidguardSigDecode(encoded)) else { continue }
            return PlaybackSource(url: source, headers: headers(referer: "https://vidguard.to"), subtitles: [], preferredPeakBitRate: nil)
        }
        throw AppError.noStream
    }

    private static func vidguardSigDecode(_ url: String) -> String {
        guard let sigRange = url.range(of: "sig=") else { return url }
        let rest = url[sigRange.upperBound...]
        let sig = String(rest.prefix { $0 != "&" })
        var decoded = ""
        var index = sig.startIndex
        while index < sig.endIndex {
            let next = sig.index(index, offsetBy: 2, limitedBy: sig.endIndex) ?? sig.endIndex
            if let byte = UInt8(sig[index..<next], radix: 16) {
                decoded.append(Character(UnicodeScalar(byte ^ 2) ?? " "))
            }
            index = next
        }
        let padded = decoded + String(repeating: "=", count: (4 - decoded.count % 4) % 4)
        guard let data = Data(base64Encoded: padded, options: [.ignoreUnknownCharacters]),
              var stage = String(data: data, encoding: .utf8) else { return url }
        stage = String(stage.dropLast(5))
        var swapped = Array(stage.reversed())
        var i = 0
        while i + 1 < swapped.count {
            swapped.swapAt(i, i + 1)
            i += 2
        }
        let decodedSig = String(swapped).dropLast(5)
        return url.replacingOccurrences(of: sig, with: String(decodedSig))
    }

    /// Closeload / Ridorapid: a `dc_*` function decrypts an array literal via a
    /// script-defined op chain (atob / reverse / rot-N) followed by an
    /// accumulator unmix loop. Ops and constants are read off the page.
    private static func closeload(_ url: URL, referer: URL?) async throws -> PlaybackSource {
        var html = try await http.page(url, referer: referer)
        for script in HosterResolver.scriptBodies(in: html) {
            if let unpacked = JSPacker.unpack(script) { html += "\n" + unpacked }
        }
        let funcPattern = #"function\s+(dc_[a-zA-Z0-9_]+)\(value_parts\)\s*\{([\s\S]*?return unmix;?)\s*\}"#
        guard let funcMatch = AnimeHTML.captures(funcPattern, in: html).first else { throw AppError.noStream }
        let funcName = funcMatch[1], funcBody = funcMatch[2]

        var operations: [(String, Int?)] = []
        let opPattern = #"(atob\()|(reverse\(\))|(replace\(\/\[a-zA-Z\]\/g[\s\S]*?o\s*-\s*base\s*\+\s*(\d+)\s*\)\s*%\s*26)"#
        for op in AnimeHTML.captures(opPattern, in: funcBody) {
            if !op[1].isEmpty { operations.append(("atob", nil)) }
            else if !op[2].isEmpty { operations.append(("reverse", nil)) }
            else if !op[3].isEmpty { operations.append(("rot", Int(op[4]))) }
        }

        var accInit = 2, accAdd = 9
        if let value = AnimeHTML.captures(#"var\s+acc\s*=\s*(\d+)"#, in: funcBody).first?[1], let parsed = Int(value) { accInit = parsed }
        if let value = AnimeHTML.captures(#"acc\s*=\s*\(\s*acc\s*\+\s*(\d+)\s*\)\s*%\s*256"#, in: funcBody).first?[1], let parsed = Int(value) { accAdd = parsed }

        let arrayPattern = funcName + #"\(\s*\[\s*((?:"[^"]+",?\s*)+)\s*\]\s*\)"#
        for arrayMatch in AnimeHTML.captures(arrayPattern, in: html) {
            let parts = AnimeHTML.captures(#""([^"]+)""#, in: arrayMatch[1]).map { $0[1] }
            var value = parts.joined().replacingOccurrences(of: "\\/", with: "/")
            var bytes: [UInt8]? = nil
            var success = true
            for (op, parameter) in operations {
                switch op {
                case "atob":
                    let input = bytes.map { String(decoding: $0, as: UTF8.self) } ?? value
                    guard let decoded = ExtendedCrypto.b64Decode(input) else { success = false; break }
                    bytes = decoded
                    value = String(decoding: decoded, as: UTF8.self)
                case "reverse":
                    value = String(value.reversed())
                    bytes = nil
                case "rot":
                    let offset = parameter ?? 0
                    value = String(value.map { char -> Character in
                        guard let ascii = char.asciiValue else { return char }
                        switch ascii {
                        case 97...122: return Character(UnicodeScalar((ascii - 97 + UInt8(offset)) % 26 + 97))
                        case 65...90: return Character(UnicodeScalar((ascii - 65 + UInt8(offset)) % 26 + 65))
                        default: return char
                        }
                    })
                    bytes = nil
                default:
                    break
                }
                if !success { break }
            }
            guard success else { continue }
            let finalBytes = bytes ?? Array(value.utf8)
            var acc = accInit
            var unmixBytes: [UInt8] = []
            unmixBytes.reserveCapacity(finalBytes.count)
            for b in finalBytes {
                acc = (acc + accAdd) % 256
                unmixBytes.append(b ^ UInt8(truncatingIfNeeded: acc))
                acc = (acc + Int(b)) % 256
            }
            let unmix = String(decoding: unmixBytes, as: UTF8.self)
            let candidate = unmix.trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.hasPrefix("http"), let source = URL(string: candidate) {
                return PlaybackSource(url: source, headers: headers(referer: url.origin + "/"), subtitles: [], preferredPeakBitRate: nil)
            }
        }
        throw AppError.noStream
    }

    /// ChillX: the player blob is AES-CBC (OpenSSL `EVP_BytesToKey` KDF)
    /// encrypted; keys come from the community keys feed.
    private static func chillx(_ url: URL, referer: URL?) async throws -> PlaybackSource {
        let html = try await http.page(url, referer: referer)
        guard let content = AnimeHTML.captures(#"\s=\s*'([^']+)"#, in: html).first?[1] else { throw AppError.noStream }
        guard let keysURL = URL(string: "https://raw.githubusercontent.com/Rowdy-Avocado/multi-keys/keys/index.html"),
              let keys = try? await http.jsonObject(keysURL),
              let list = keys["chillx"] as? [String], let key = list.first else { throw AppError.noStream }
        guard let decrypted = ExtendedCrypto.openSSLAESDecrypt(content, passphrase: Array(key.utf8))?
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\", with: "") else { throw AppError.noStream }
        guard let raw = AnimeHTML.captures(#""?file"?\s*:\s*"([^"]+)"#, in: decrypted).first?[1],
              let source = ProviderNetwork.absolute(raw, relativeTo: url) else { throw AppError.noStream }
        let subs = AnimeHTML.captures(#"\{"file":"([^"]+)","label":"([^"]+)","kind":"captions""#, in: decrypted).compactMap { match -> SubtitleSource? in
            guard let sub = ProviderNetwork.absolute(match[1], relativeTo: url) else { return nil }
            return SubtitleSource(providerID: "chillx", providerName: "ChillX",
                                  label: match[2], languageCode: AnimeStreamResolver.languageCode(match[2]), url: sub)
        }
        return PlaybackSource(url: source, headers: headers(referer: "https://chillx.top"), subtitles: subs, preferredPeakBitRate: nil)
    }

    // MARK: - Delegating wrappers

    /// Upzone: the page either carries the m3u8 directly or delegates to a
    /// real hoster via button/iframe/script URLs.
    private static func upzone(_ url: URL, referer: URL?, depth: Int) async throws -> PlaybackSource {
        let refererValue = url.queryParam("reff").flatMap {
            $0.hasPrefix("http") ? $0 : "https://\($0)/"
        } ?? url.origin + "/"
        let html = try await http.page(url, referer: URL(string: refererValue))
        let patterns = [
            #"["']file["']\s*[:=]\s*["']((?:https?://|/)[^"']+\.m3u8[^"']*)["']"#,
            #"["']src["']\s*[:=]\s*["']((?:https?://|/)[^"']+\.m3u8[^"']*)["']"#,
            #"["']hls\d*["']\s*[:=]\s*["']((?:https?://|/)[^"']+\.m3u8[^"']*)["']"#,
            #"source\s*=\s*["']((?:https?://|/)[^"']+\.m3u8[^"']*)["']"#,
            #"(https?://[^"'\s\\<]+\.m3u8[^"'\s\\<]*)"#,
        ]
        let texts = unpackedScripts(in: html) + [html]
        if let source = firstSource(in: texts, patterns: patterns, relativeTo: url) {
            return PlaybackSource(
                url: source,
                headers: headers(referer: refererValue, origin: url.origin, extra: ["Accept": "*/*"]),
                subtitles: [],
                preferredPeakBitRate: nil
            )
        }
        // Delegation: iframe, `a.buttonprch`, or any external URL in scripts.
        var delegated: [String] = AnimeHTML.captures(#"<iframe[^>]+src=["']([^"']+)["']"#, in: html).map { $0[1] }
        delegated += AnimeHTML.captures(#"a[^>]+class=["'][^"']*buttonprch[^"']*["'][^>]+href=["']([^"']+)["']"#, in: html).map { $0[1] }
        for script in HosterResolver.scriptBodies(in: html) {
            delegated += AnimeHTML.captures(#"https?://[^"'\s\\<]+"#, in: script).map { $0[0] }
        }
        for raw in delegated {
            guard let next = ProviderNetwork.absolute(raw, relativeTo: url), next != url,
                  !(next.hostName ?? "").contains("upzone") else { continue }
            if let source = try? await ExtendedHosterExtractor.resolve(next, referer: url, depth: depth + 1) {
                return source
            }
            if let source = try? await HosterExtractor.resolve(next, referer: url, depth: depth + 1) {
                return source
            }
        }
        throw AppError.noStream
    }

    /// Nuupload: same delegation shape plus an obfuscated base64 session URL.
    private static func nuupload(_ url: URL, referer: URL?, depth: Int) async throws -> PlaybackSource {
        // Some Nuupload links wrap another hoster in `?url=`.
        if let nested = url.queryParam("url"), nested.hasPrefix("http"), let nestedURL = URL(string: nested) {
            if let source = try? await ExtendedHosterExtractor.resolve(nestedURL, referer: url, depth: depth + 1) { return source }
            if let source = try? await HosterExtractor.resolve(nestedURL, referer: url, depth: depth + 1) { return source }
        }
        let html = try await http.page(url, referer: referer ?? url)
        let texts = unpackedScripts(in: html) + [html]
        if let source = firstSource(in: texts, patterns: commonSourcePatterns, relativeTo: url) {
            return PlaybackSource(url: source, headers: headers(referer: url.origin + "/", origin: url.origin), subtitles: [], preferredPeakBitRate: nil)
        }
        // Obfuscated `String.fromCharCode(parseInt(atob(value)) - N)` + `sesz`.
        if let source = nuuploadObfuscated(in: html, relativeTo: url) {
            return PlaybackSource(url: source, headers: headers(referer: url.origin + "/", origin: url.origin), subtitles: [], preferredPeakBitRate: nil)
        }
        var delegated: [String] = AnimeHTML.captures(#"<iframe[^>]+src=["']([^"']+)["']"#, in: html).map { $0[1] }
        delegated += AnimeHTML.captures(#"a[^>]+href=["']([^"']*(?:embed|watch|voe|filemoon)[^"']*)["']"#, in: html).map { $0[1] }
        delegated += AnimeHTML.captures(#"(?:https?:)?//[^"'\s\\<]+(?:voe|streamtape|filemoon|vidhide|streamwish|upzone)[^"'\s\\<]*"#, in: html).map { $0[0] }
        for raw in delegated {
            guard let next = ProviderNetwork.absolute(raw, relativeTo: url), next != url else { continue }
            let host = next.hostName?.lowercased() ?? ""
            if host.contains("nupload") || host.contains("nupupload") { continue }
            if let source = try? await ExtendedHosterExtractor.resolve(next, referer: url, depth: depth + 1) {
                return source
            }
            if let source = try? await HosterExtractor.resolve(next, referer: url, depth: depth + 1) {
                return source
            }
        }
        throw AppError.noStream
    }

    private static func nuuploadObfuscated(in html: String, relativeTo base: URL) -> URL? {
        guard let offsetRaw = AnimeHTML.captures(
            #"String\.fromCharCode\(parseInt\(atob\(value\)\.replace\(/\\D/g,''\)\)\s*-\s*(\d+)\)"#,
            in: html
        ).first?[1], let offset = Int(offsetRaw),
              let arrayContent = AnimeHTML.captures(
                  #"var\s+\w+\s*=\s*\[((?:"[^"]*"|'[^']*')(?:\s*,\s*(?:"[^"]*"|'[^']*'))*)]"#,
                  in: html
              ).first?[1] else { return nil }
        let parts = AnimeHTML.captures(#"["']([^"']+)["']"#, in: arrayContent).map { $0[1] }
        var built = ""
        for part in parts {
            guard let decoded = ExtendedCrypto.b64DecodeString(part) else { continue }
            let numeric = decoded.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
            guard let code = Int(numeric), let scalar = UnicodeScalar(code - offset) else { continue }
            built.append(Character(scalar))
        }
        var final = built.trimmingCharacters(in: .whitespacesAndNewlines)
        guard final.hasPrefix("http") else { return nil }
        if let session = AnimeHTML.captures(#"var\s+sesz\s*=\s*["']([^"']+)["']"#, in: html).first?[1], !session.isEmpty {
            final += final.contains("?") ? "&s=\(session)" : "?s=\(session)"
        }
        return ProviderNetwork.absolute(final, relativeTo: base)
    }

    // MARK: - Filemoon (attested playback API)

    /// Filemoon requires an ECDSA attestation round-trip before the (AES-GCM
    /// encrypted) playback manifest is handed out. Ported from the Android
    /// `FilemoonExtractor` 4-step flow: details → challenge → attest → playback.
    private static func filemoon(_ url: URL) async throws -> PlaybackSource {
        guard let idMatch = AnimeHTML.captures(#"/(e|d)/([a-zA-Z0-9]+)"#, in: url.absoluteString).first else {
            throw AppError.noStream
        }
        let linkType = idMatch[1]
        let videoID = idMatch[2]
        let ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36"

        guard let detailsURL = URL(string: "\(url.origin)/api/videos/\(videoID)/embed/details") else { throw AppError.invalidURL }
        let details = try await http.jsonObject(detailsURL, headers: ["User-Agent": ua])
        guard let embedFrame = details["embed_frame_url"] as? String,
              let frameURL = URL(string: embedFrame) else { throw AppError.noStream }
        let playbackDomain = frameURL.origin

        let apiHeaders = ["Referer": embedFrame, "Origin": playbackDomain, "User-Agent": ua]
        guard let challengeURL = URL(string: "\(playbackDomain)/api/videos/access/challenge") else { throw AppError.invalidURL }
        let challengeResponse = try await http.send(
            HosterHTTP.jsonRequest(url: challengeURL, headers: apiHeaders, body: [:])
        )
        guard let challenge = try? JSONSerialization.jsonObject(with: challengeResponse.data) as? [String: Any] else { throw AppError.noStream }
        guard let challengeID = challenge["challenge_id"] as? String,
              let nonce = challenge["nonce"] as? String else { throw AppError.noStream }

        var viewerID = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var deviceID = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let attestation = ExtendedCrypto.ecdsaAttestation(nonce: nonce)

        let attestBody: [String: Any] = [
            "viewer_id": viewerID,
            "device_id": deviceID,
            "challenge_id": challengeID,
            "nonce": nonce,
            "signature": attestation.signature,
            "public_key": attestation.publicKey,
            "client": [
                "user_agent": ua,
                "architecture": "x86",
                "bitness": "64",
                "platform": "Windows",
                "platform_version": "10.0.0",
                "pixel_ratio": 1.0,
                "screen_width": 1920,
                "screen_height": 1080,
                "languages": ["en-US"],
            ] as [String: Any],
            "storage": [
                "cookie": viewerID,
                "local_storage": viewerID,
                "indexed_db": "\(viewerID):\(deviceID)",
                "cache_storage": "\(viewerID):\(deviceID)",
            ] as [String: Any],
            "attributes": ["entropy": "high"],
        ]
        guard let attestURL = URL(string: "\(playbackDomain)/api/videos/access/attest") else { throw AppError.invalidURL }
        let attestResponse = try await http.send(
            HosterHTTP.jsonRequest(url: attestURL, headers: apiHeaders, body: attestBody)
        )
        guard let attest = try? JSONSerialization.jsonObject(with: attestResponse.data) as? [String: Any],
              let token = attest["token"] as? String,
              let confidence = attest["confidence"] as? Double, confidence > 0 else { throw AppError.noStream }
        viewerID = attest["viewer_id"] as? String ?? viewerID
        deviceID = attest["device_id"] as? String ?? deviceID

        let playbackBody: [String: Any] = [
            "fingerprint": [
                "token": token,
                "viewer_id": viewerID,
                "device_id": deviceID,
                "confidence": confidence,
            ] as [String: Any],
        ]
        guard let playbackURL = URL(string: "\(playbackDomain)/api/videos/\(videoID)/embed/playback") else { throw AppError.invalidURL }
        var playbackHeaders = apiHeaders
        playbackHeaders["X-Embed-Parent"] = linkType == "e" ? url.absoluteString : ""
        let playbackResponse = try await http.send(
            HosterHTTP.jsonRequest(url: playbackURL, headers: playbackHeaders, body: playbackBody)
        )
        guard let playback = try? JSONSerialization.jsonObject(with: playbackResponse.data) as? [String: Any],
              let data = playback["playback"] as? [String: Any],
              let decrypted = filemoonDecrypt(data),
              let decryptedData = decrypted.data(using: .utf8),
              let manifest = try? JSONSerialization.jsonObject(with: decryptedData) as? [String: Any],
              let sources = manifest["sources"] as? [[String: Any]],
              let raw = sources.first?["url"] as? String,
              let source = URL(string: raw) else { throw AppError.noStream }
        return PlaybackSource(
            url: source,
            headers: ["Referer": embedFrame, "Origin": playbackDomain, "User-Agent": ua],
            subtitles: [],
            preferredPeakBitRate: nil
        )
    }

    /// playback payload: AES-GCM, key = key_parts[0] + key_parts[1] (b64url).
    private static func filemoonDecrypt(_ data: [String: Any]) -> String? {
        guard let ivRaw = data["iv"] as? String,
              let payloadRaw = data["payload"] as? String,
              let parts = data["key_parts"] as? [String], parts.count >= 2,
              let iv = ExtendedCrypto.b64Decode(ivRaw),
              let payload = ExtendedCrypto.b64Decode(payloadRaw),
              let p1 = ExtendedCrypto.b64Decode(parts[0]),
              let p2 = ExtendedCrypto.b64Decode(parts[1]) else { return nil }
        let key = p1 + p2
        do {
            let sealedBox = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: Data(iv)),
                ciphertext: Data(payload.dropLast(16)),
                tag: Data(payload.suffix(16))
            )
            let opened = try AES.GCM.open(sealedBox, using: SymmetricKey(data: Data(key)))
            return String(data: opened, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

// MARK: - Crypto primitives

enum ExtendedCrypto {

    static func b64Decode(_ value: String) -> [UInt8]? {
        let compact = value.components(separatedBy: .whitespacesAndNewlines).joined()
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = compact + String(repeating: "=", count: (4 - compact.count % 4) % 4)
        guard let data = Data(base64Encoded: padded, options: [.ignoreUnknownCharacters]) else { return nil }
        return Array(data)
    }

    static func b64DecodeString(_ value: String) -> String? {
        b64Decode(value).flatMap { String(decoding: $0, as: UTF8.self) }
    }

    static func b64EncodeURL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// AES-128-CBC decrypt of a hex string with PKCS7 padding.
    static func aesCBCDecryptHex(_ hex: String, key: [UInt8], iv: [UInt8]) -> String? {
        let cleaned = hex.lowercased().filter { "0123456789abcdef".contains($0) }
        var bytes: [UInt8] = []
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2, limitedBy: cleaned.endIndex) ?? cleaned.endIndex
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { break }
            bytes.append(byte)
            index = next
        }
        return aesCBCDecrypt(bytes, key: key, iv: iv)
    }

    static func aesCBCDecrypt(_ ciphertext: [UInt8], key: [UInt8], iv: [UInt8]) -> String? {
        var outLength = 0
        var out = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        let status = ciphertext.withUnsafeBytes { cipherBuffer in
            key.withUnsafeBytes { keyBuffer in
                iv.withUnsafeBytes { ivBuffer in
                    out.withUnsafeMutableBytes { outBuffer in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuffer.baseAddress, key.count,
                            ivBuffer.baseAddress,
                            cipherBuffer.baseAddress, ciphertext.count,
                            outBuffer.baseAddress, outBuffer.count,
                            &outLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return String(decoding: out.prefix(outLength), as: UTF8.self)
    }

    /// OpenSSL `EVP_BytesToKey` (MD5 chain) + AES-CBC decrypt for the
    /// `{"ct","iv","s"}` envelopes ChillX uses.
    static func openSSLAESDecrypt(_ json: String, passphrase: [UInt8]) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ct = object["ct"] as? String,
              let ivHex = object["iv"] as? String,
              let saltHex = object["s"] as? String,
              let salt = hexBytes(saltHex), let iv = hexBytes(ivHex),
              let ciphertext = Data(base64Encoded: ct) else { return nil }
        let keyLength = 32
        let ivLength = iv.count
        let digestLength = 16 // MD5
        var generated: [UInt8] = []
        var block: [UInt8] = []
        while generated.count < keyLength + ivLength {
            var hasher = Insecure.MD5()
            hasher.update(data: Data(block + passphrase + salt))
            block = Array(hasher.finalize())
            generated += block
            _ = digestLength
        }
        let key = Array(generated.prefix(keyLength))
        let derivedIV = Array(generated[keyLength..<(keyLength + ivLength)])
        return aesCBCDecrypt(Array(ciphertext), key: key, iv: derivedIV)
    }

    static func hexBytes(_ hex: String) -> [UInt8]? {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    /// P-256 ECDSA attestation: signature over the nonce (raw r||s, base64url)
    /// plus the public key as a JWK dictionary.
    static func ecdsaAttestation(nonce: String) -> (signature: String, publicKey: [String: Any]) {
        let key = P256.Signing.PrivateKey()
        let signature = try! key.signature(for: Data(nonce.utf8))
        let raw = signature.rawRepresentation
        let publicKeyRaw = key.publicKey.rawRepresentation // 0x04 || X || Y
        let x = Data(publicKeyRaw.dropFirst().prefix(32))
        let y = Data(publicKeyRaw.suffix(32))
        let jwk: [String: Any] = [
            "crv": "P-256",
            "ext": true,
            "key_ops": ["verify"],
            "kty": "EC",
            "x": b64EncodeURL(x),
            "y": b64EncodeURL(y),
        ]
        return (b64EncodeURL(raw), jwk)
    }
}

// MARK: - URL conveniences

private extension URL {
    func queryParam(_ name: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == name })?.value
    }
}

// MARK: - NetPrime embed APIs (Vidrock / Videasy / Vidzee / PrimeSrc / VidLink / 2Embed)

/// TMDB-keyed stream APIs NetPrime exposes as its server set. API-backed
/// servers resolve at playback time; iframe-only ones go through the resolvers.
enum NetPrimeEmbeds {
    struct Target: Sendable {
        let tmdbID: Int
        let imdbID: String?
        let title: String
        let year: Int?
        let season: Int?
        let episode: Int?

        var isEpisode: Bool { season != nil && episode != nil }

        init?(context: PlaybackLookupContext) {
            guard let tmdb = context.request.media.tmdbID else { return nil }
            tmdbID = tmdb
            imdbID = context.request.media.imdbID
            title = context.request.media.title
            year = AnimeMatching.year(context.request.media.releaseDate)
            season = context.request.episode?.seasonNumber
            episode = context.request.episode?.number
        }
    }

    static let browserUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36"
    private static var http: HosterHTTP { HosterHTTP.shared }

    // MARK: Vidrock

    private static let vidrockBase = URL(string: "https://vidrock.net/")!

    static func vidrock(_ target: Target) async -> [HosterLink] {
        let plain = target.isEpisode
            ? "\(target.tmdbID)_\(target.season ?? 1)_\(target.episode ?? 1)"
            : "\(target.tmdbID)"
        let key = Array("x7k9mPqT2rWvY8zA5bC3nF6hJ2lK4mN9".utf8)
        guard let sealed = aesCBC(kCCEncrypt, Array(plain.utf8), key: key, iv: Array(key.prefix(16))) else { return [] }
        let token = Data(sealed).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let headers = ["User-Agent": browserUA, "Origin": "https://vidrock.net"]
        guard let api = URL(string: "https://vidrock.net/api/\(target.isEpisode ? "tv" : "movie")/\(token)"),
              let root = try? await http.jsonObject(api, referer: vidrockBase, headers: headers) else { return [] }
        return root.keys.sorted().compactMap { name in
            guard let raw = (root[name] as? [String: Any])?["url"] as? String, !raw.isEmpty,
                  let stream = URL(string: raw) else { return nil }
            return HosterLink(name: "\(name) (Vidrock)", url: stream, referer: vidrockBase, resolveOverride: {
                var file = stream
                if name.caseInsensitiveCompare("Atlas") == .orderedSame,
                   let qualities = try? await http.json(stream, referer: vidrockBase, headers: headers) as? [[String: Any]],
                   let best = qualities.max(by: { ($0["resolution"] as? Int ?? 0) < ($1["resolution"] as? Int ?? 0) }),
                   let raw = best["url"] as? String, let mp4 = URL(string: raw) {
                    file = mp4
                }
                return PlaybackSource(
                    url: file,
                    headers: ["Referer": vidrockBase.absoluteString, "Origin": "https://vidrock.net", "User-Agent": browserUA],
                    subtitles: [],
                    preferredPeakBitRate: nil
                )
            })
        }
    }

    // MARK: PrimeSrc

    private static let primeBase = URL(string: "https://primesrc.me/")!

    static func primeSrc(_ target: Target) async -> [HosterLink] {
        var query = "tmdb=\(target.tmdbID)&type=\(target.isEpisode ? "tv" : "movie")"
        if let season = target.season, let episode = target.episode { query += "&season=\(season)&episode=\(episode)" }
        let headers = ["User-Agent": browserUA]
        guard let api = URL(string: "https://primesrc.me/api/v1/s?\(query)"),
              let root = try? await http.jsonObject(api, referer: primeBase, headers: headers) else { return [] }
        var counts: [String: Int] = [:]
        return (root["servers"] as? [[String: Any]] ?? []).compactMap { server in
            guard let name = server["name"] as? String, let key = server["key"] as? String,
                  let link = URL(string: "https://primesrc.me/api/v1/l?key=\(ProviderNetwork.encoded(key))") else { return nil }
            let count = (counts[name] ?? 0) + 1
            counts[name] = count
            return HosterLink(name: "\(count > 1 ? "\(name) \(count)" : name) (PrimeSrc)", url: link, referer: primeBase, resolveOverride: {
                let response = try await http.jsonObject(link, referer: primeBase, headers: headers)
                guard let raw = (response["link"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      raw.lowercased().hasPrefix("http"), let embed = URL(string: raw),
                      let host = embed.host, !host.isEmpty, host != "_" else { throw AppError.invalidResponse }
                return try await HosterResolver(client: ProviderHTTP.shared).resolve(embed, referer: primeBase)
            })
        }
    }

    // MARK: Videasy

    private static let videasyServers = [
        ("Yoru", "cdn"), ("Cypher", "downloader2"), ("Breach", "m4uhd"), ("Neon", "vsrc"), ("Vyse", "hdmovie"),
    ]

    static func videasy(_ target: Target) -> [HosterLink] {
        let referer = URL(string: "https://player.videasy.net/")!
        return videasyServers.compactMap { name, endpoint in
            var components = URLComponents(string: "https://api.speedracelight.com/\(endpoint)/sources-with-title")
            var items = [
                URLQueryItem(name: "title", value: target.title),
                URLQueryItem(name: "mediaType", value: target.isEpisode ? "tv" : "movie"),
                URLQueryItem(name: "year", value: target.year.map(String.init) ?? ""),
                URLQueryItem(name: "tmdbId", value: String(target.tmdbID)),
                URLQueryItem(name: "imdbId", value: target.imdbID ?? ""),
            ]
            if let season = target.season, let episode = target.episode {
                items += [URLQueryItem(name: "episodeId", value: String(episode)), URLQueryItem(name: "seasonId", value: String(season))]
            }
            components?.queryItems = items
            guard let url = components?.url else { return nil }
            let tmdb = String(target.tmdbID)
            return HosterLink(name: "\(name) (Videasy)", url: url, referer: referer, resolveOverride: {
                let response = try await http.send(HosterHTTP.request(url: url, headers: ["User-Agent": browserUA]))
                let cipher = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard response.statusCode == 200, !cipher.isEmpty, !cipher.hasPrefix("<"), !cipher.hasPrefix("{") else {
                    throw AppError.invalidResponse
                }
                let decrypted = try await http.send(HosterHTTP.jsonRequest(
                    url: URL(string: "https://enc-dec.app/api/dec-videasy")!,
                    body: ["text": cipher, "id": tmdb]
                ))
                let outer = (try? JSONSerialization.jsonObject(with: decrypted.data)) as? [String: Any]
                let inner = (outer?["result"] as? [String: Any])
                    ?? (outer?["result"] as? String).flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
                guard let raw = ((inner?["sources"] as? [[String: Any]])?.first?["url"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      let stream = URL(string: raw) else { throw AppError.invalidResponse }
                return PlaybackSource(
                    url: stream,
                    headers: ["Referer": referer.absoluteString, "User-Agent": browserUA],
                    subtitles: subtitles(inner?["subtitles"], provider: "Videasy"),
                    preferredPeakBitRate: nil
                )
            })
        }
    }

    // MARK: Vidzee

    private static let vidzeeServers = [
        "Nflix", "Duke", "Glory", "Nazy", "Atlas", "Drag", "Achilles",
        "Viet", "Velocità", "Hindi", "Bengali", "Tamil", "Telugu", "Malayalam",
    ]
    private static let vidzeeReferer = URL(string: "https://player.vidzee.wtf/")!
    private static let vidzeeHeaders = [
        "User-Agent": browserUA,
        "Origin": "https://player.vidzee.wtf",
        "Accept": "application/json,text/plain,*/*",
    ]

    static func vidzee(_ target: Target) -> [HosterLink] {
        var base = "https://player.vidzee.wtf/api/server?id=\(target.tmdbID)"
        if let season = target.season, let episode = target.episode { base += "&ss=\(season)&ep=\(episode)" }
        return vidzeeServers.enumerated().compactMap { index, name in
            guard let link = URL(string: "\(base)&sr=\(index)") else { return nil }
            return HosterLink(name: "\(name) (Vidzee)", url: link, referer: vidzeeReferer, resolveOverride: {
                if index != 0, let source = try? await vidzeeLegacy(link) { return source }
                if let source = await vidzeeDirect(target, sr: index) { return source }
                return try await vidzeeLegacy(link)
            })
        }
    }

    private static func vidzeeDirect(_ target: Target, sr: Int) async -> PlaybackSource? {
        let defaults = target.isEpisode ? ["ipcloud", "dcloud", "tik"] : ["dcloud", "tik", "ipcloud"]
        let preferred: String?
        switch sr {
        case 1: preferred = "dcloud"
        case 2...6: preferred = "tik"
        case 7...13: preferred = "ipcloud"
        default: preferred = nil
        }
        let order = preferred.map { first in [first] + defaults.filter { $0 != first } } ?? defaults
        let path = target.isEpisode
            ? "tv/\(target.tmdbID)/\(target.season ?? 1)/\(target.episode ?? 1)"
            : "movie/\(target.tmdbID)"
        for server in order {
            guard let url = URL(string: "https://core.vidzee.wtf/streams/\(path)?s=\(server)&e=0"),
                  let root = try? await http.jsonObject(url, referer: vidzeeReferer, headers: vidzeeHeaders),
                  let raw = (root["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
                  let stream = URL(string: raw) else { continue }
            var headers = vidzeeHeaders
            headers["Referer"] = vidzeeReferer.absoluteString
            headers["Accept"] = nil
            for (key, value) in root["headers"] as? [String: String] ?? [:] { headers[key] = value }
            return PlaybackSource(
                url: stream,
                headers: headers,
                subtitles: subtitles(root["tracks"] ?? root["subtitles"], provider: "Vidzee"),
                preferredPeakBitRate: nil
            )
        }
        return nil
    }

    /// Server links carry an AES-CBC link keyed by a master key that
    /// `core.vidzee.wtf/api-key` hands out AES-GCM sealed under a static pass.
    private static func vidzeeLegacy(_ link: URL) async throws -> PlaybackSource {
        let keyResponse = try await http.send(HosterHTTP.request(
            url: URL(string: "https://core.vidzee.wtf/api-key")!,
            referer: vidzeeReferer,
            headers: vidzeeHeaders
        ))
        guard let blob = ExtendedCrypto.b64Decode(keyResponse.text), blob.count > 28 else { throw AppError.invalidResponse }
        let gcmKey = SymmetricKey(data: SHA256.hash(data: Data("4f2a9c7d1e8b3a6f0d5c2e9a7b1f4d8c".utf8)))
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: Data(blob[0..<12])),
            ciphertext: Data(blob[28...]),
            tag: Data(blob[12..<28])
        )
        let master = Array(try AES.GCM.open(box, using: gcmKey))

        let root = try await http.jsonObject(link, referer: vidzeeReferer, headers: vidzeeHeaders)
        guard let encrypted = (root["url"] as? [[String: Any]])?.first?["link"] as? String,
              let wrapped = ExtendedCrypto.b64Decode(encrypted),
              let parts = String(bytes: wrapped, encoding: .utf8)?.split(separator: ":"), parts.count >= 2,
              let iv = ExtendedCrypto.b64Decode(String(parts[0])),
              let cipher = ExtendedCrypto.b64Decode(String(parts[1])) else { throw AppError.invalidResponse }
        var key = Array(master.prefix(32))
        key += [UInt8](repeating: 0, count: 32 - key.count)
        guard let plain = aesCBC(kCCDecrypt, cipher, key: key, iv: iv),
              let raw = String(bytes: plain, encoding: .utf8), let stream = URL(string: raw) else { throw AppError.invalidResponse }
        var headers = vidzeeHeaders
        headers["Referer"] = vidzeeReferer.absoluteString
        headers["Accept"] = nil
        return PlaybackSource(url: stream, headers: headers, subtitles: subtitles(root["tracks"], provider: "Vidzee"), preferredPeakBitRate: nil)
    }

    // MARK: VidLink / Vidnest / 2Embed (iframe servers)

    /// VidLink only reveals its playlist to a JS player, so it is handed to the
    /// resolvers as an embed like NetPrime's Vidnest alias.
    static func embeds(_ target: Target) -> [HosterLink] {
        let id = target.tmdbID
        var urls: [(String, String)]
        if let season = target.season, let episode = target.episode {
            urls = [
                ("Vidnest", "https://vidnest.fun/tv/\(id)/\(season)/\(episode)"),
                ("VidLink", "https://vidlink.pro/tv/\(id)/\(season)/\(episode)"),
                ("2Embed", "https://www.2embed.cc/embedtv/\(id)?s=\(season)&e=\(episode)"),
            ]
        } else {
            urls = [
                ("Vidnest", "https://vidnest.fun/movie/\(id)"),
                ("VidLink", "https://vidlink.pro/movie/\(id)"),
                ("2Embed", "https://www.2embed.cc/embed/\(id)"),
            ]
        }
        return urls.compactMap { name, raw in URL(string: raw).map { HosterLink(name: name, url: $0) } }
    }

    /// 2Embed's page lazy-loads a player iframe; `id=` players are uqloads
    /// (streamwish) files, anything else is resolved as a regular hoster.
    static func twoEmbed(_ url: URL, depth: Int) async throws -> PlaybackSource? {
        let html = try await http.page(url, referer: URL(string: "https://www.2embed.cc/"), headers: ["User-Agent": browserUA])
        guard let raw = AnimeHTML.parse(html).first({ $0.tag == "iframe" && !$0["data-src"].isEmpty })?["data-src"],
              let frame = URL(string: raw) else { return nil }
        if let id = AnimeHTML.captures(#"[?&]id=([^&]+)"#, in: raw).first?[1],
           let uqloads = URL(string: "https://uqloads.xyz/e/\(id)") {
            let origin = URL(string: "\(frame.scheme ?? "https")://\(frame.host ?? "")/")
            return try await ExtendedHosterExtractor.resolve(uqloads, referer: origin, serverName: "streamwish", depth: depth + 1)
        }
        if let source = try? await ExtendedHosterExtractor.resolve(frame, referer: url, depth: depth + 1) {
            return source
        }
        return try await HosterExtractor.resolve(frame, referer: url, depth: depth + 1)
    }

    // MARK: Helpers

    private static func subtitles(_ value: Any?, provider: String) -> [SubtitleSource] {
        (value as? [[String: Any]] ?? []).compactMap { track in
            guard let raw = (track["url"] as? String) ?? (track["file"] as? String), let url = URL(string: raw) else { return nil }
            let label = (track["lang"] as? String) ?? (track["label"] as? String) ?? "Unknown"
            return SubtitleSource(
                providerID: provider.lowercased(),
                providerName: provider,
                label: label,
                languageCode: AnimeStreamResolver.languageCode(label),
                url: url
            )
        }
    }

    private static func aesCBC(_ operation: Int, _ input: [UInt8], key: [UInt8], iv: [UInt8]) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        let capacity = output.count
        var moved = 0
        let status = CCCrypt(
            CCOperation(operation), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
            key, key.count, iv, input, input.count, &output, capacity, &moved
        )
        guard status == kCCSuccess else { return nil }
        return Array(output.prefix(moved))
    }
}
