import Foundation
@preconcurrency import Network

// Loopback reverse proxy for remote streams. AVURLAssetHTTPHeaderFieldsKey does
// not forward headers (Referer above all) to HLS variant playlist and segment
// requests, so most hoster streams fail in AVPlayer even though extraction
// succeeded. Routing every playlist and segment through this proxy lets each
// upstream request carry the extractor's headers, like ExoPlayer does.
@MainActor
final class HLSProxyServer {
    static let shared = HLSProxyServer()

    private var listener: NWListener?
    private var listenerPort: NWEndpoint.Port?
    private var listenerError: NWError?
    private var headerSets: [String: [String: String]] = [:]
    private var tokensByCanonicalHeaders: [String: String] = [:]
    private var requestBuffers: [ObjectIdentifier: Data] = [:]
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var activeFetches: [ObjectIdentifier: ProxyFetchHandler] = [:]

    private init() {}

    deinit {
        listener?.cancel()
        for connection in connections.values { connection.cancel() }
    }

    /// Verified against live hoster CDNs (dropcdn): signed stream URLs reject any
    /// request without the extractor's UA+Referer — including AVPlayer's HLS
    /// subrequests, which never inherit AVURLAssetHTTPHeaderFieldsKey. The proxy
    /// is therefore required for hoster playback and stays on unless the user
    /// explicitly disables it in Settings.
    static var isEnabled: Bool {
        if UserDefaults.standard.object(forKey: "playback.hlsProxy.enabled") != nil {
            return UserDefaults.standard.bool(forKey: "playback.hlsProxy.enabled")
        }
        return true
    }

    func proxiedURL(for url: URL, headers: [String: String]) async -> URL? {
        guard Self.isEnabled else { return nil }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(),
              host != "127.0.0.1", host != "localhost" else { return nil }
        // Progressive MP4/WebM files are single requests: AVURLAssetHTTPHeaderFieldsKey
        // already carries the extractor headers there. The header-drop problem only
        // exists for HLS subrequests (variant playlists, segments), so only HLS goes
        // through the proxy — everything else keeps the direct, battle-tested path.
        let path = url.path.lowercased()
        let looksHLS = path.hasSuffix(".m3u8") || path.contains("/hls") || path.contains("m3u8")
        guard looksHLS else { return nil }
        guard let port = try? await startIfNeeded() else { return nil }
        let token = token(for: headers)
        let encoded = Data(url.absoluteString.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let pathExtension = url.pathExtension
        let fileComponent = pathExtension.isEmpty ? "stream" : "stream.\(pathExtension)"
        return URL(string: "http://127.0.0.1:\(port.rawValue)/p/\(token)/\(fileComponent)?u=\(encoded)")
    }

    /// Rewrites every absolute http(s) URI in an already-local playlist through
    /// the proxy. Used for the subtitle-injected master playlist whose variant
    /// lines still point at the origin server.
    func rewriteRemoteURLs(in playlist: String, headers: [String: String]) async -> String {
        let token = token(for: headers)
        guard let port = try? await startIfNeeded() else { return playlist }
        let prefix = "http://127.0.0.1:\(port.rawValue)/p/\(token)/"
        var output: [String] = []
        for line in playlist.components(separatedBy: "\n") {
            output.append(Self.rewriteLine(line, base: nil, prefix: prefix))
        }
        return output.joined(separator: "\n")
    }

    private func token(for headers: [String: String]) -> String {
        let canonical = headers.keys.sorted().map { "\($0)=\(headers[$0] ?? "")" }.joined(separator: "&")
        if let existing = tokensByCanonicalHeaders[canonical] { return existing }
        let newToken = UUID().uuidString
        tokensByCanonicalHeaders[canonical] = newToken
        headerSets[newToken] = headers
        return newToken
    }

    private func startIfNeeded() async throws -> NWEndpoint.Port {
        if let listenerPort { return listenerPort }
        if let listenerError { throw listenerError }
        if listener == nil {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.listenerPort = listener.port
                    case .failed(let error):
                        self.listenerError = error
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            self.listener = listener
            listener.start(queue: .main)
        }

        for _ in 0..<200 {
            if let listenerPort { return listenerPort }
            if let listenerError { throw listenerError }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AppError.providerUnavailable("The local stream proxy did not start.")
    }

    private func accept(_ connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        connections[identifier] = connection
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed, .cancelled:
                    self?.connections.removeValue(forKey: identifier)
                    self?.requestBuffers.removeValue(forKey: identifier)
                    // AVPlayer probes and aborts connections freely; the upstream
                    // download must not keep burning bandwidth afterwards.
                    self?.activeFetches.removeValue(forKey: identifier)?.cancel()
                default: break
                }
            }
        }
        connection.start(queue: .main)
        receiveRequest(on: connection)
    }

    private func receiveRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                let identifier = ObjectIdentifier(connection)
                if let data { self.requestBuffers[identifier, default: Data()].append(data) }
                if self.requestBuffers[identifier]?.range(of: Data("\r\n\r\n".utf8)) != nil {
                    let request = self.requestBuffers.removeValue(forKey: identifier) ?? Data()
                    self.handle(request: request, on: connection)
                } else if isComplete || error != nil {
                    self.requestBuffers.removeValue(forKey: identifier)
                    connection.cancel()
                } else {
                    self.receiveRequest(on: connection)
                }
            }
        }
    }

    private func handle(request: Data, on connection: NWConnection) {
        guard let requestText = String(data: request, encoding: .utf8),
              let requestLine = requestText.components(separatedBy: "\r\n").first else {
            sendSimple(status: "400 Bad Request", on: connection)
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD",
              let components = URLComponents(string: String(parts[1])),
              let target = targetURL(from: components) else {
            sendSimple(status: "400 Bad Request", on: connection)
            return
        }
        let token = components.path.components(separatedBy: "/").count > 2
            ? components.path.components(separatedBy: "/")[2] : ""
        let headers = headerSets[token] ?? [:]
        var rangeHeader: String?
        for line in requestText.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("range:") {
                rangeHeader = line.dropFirst("range:".count).trimmingCharacters(in: .whitespaces)
            }
        }
        let isHead = parts[0] == "HEAD"
        let port = listenerPort
        fetch(
            target: target,
            headers: headers,
            rangeHeader: rangeHeader,
            headOnly: isHead,
            proxyPrefix: port.map { "http://127.0.0.1:\($0.rawValue)/p/\(token)/" } ?? "",
            on: connection
        )
    }

    private func targetURL(from components: URLComponents) -> URL? {
        guard components.path.hasPrefix("/p/"),
              let encoded = components.queryItems?.first(where: { $0.name == "u" })?.value else { return nil }
        var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64),
              let text = String(data: data, encoding: .utf8),
              let url = URL(string: text) else { return nil }
        return url
    }

    private func fetch(
        target: URL,
        headers: [String: String],
        rangeHeader: String?,
        headOnly: Bool,
        proxyPrefix: String,
        on connection: NWConnection
    ) {
        var request = URLRequest(url: target)
        if headOnly { request.httpMethod = "HEAD" }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(HTTPClient.desktopUserAgent, forHTTPHeaderField: "User-Agent")
        }
        // Passthrough streaming must not decompress in flight: the forwarded
        // Content-Length would no longer match the body AVPlayer receives.
        if request.value(forHTTPHeaderField: "Accept-Encoding") == nil {
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        }
        if let rangeHeader, request.value(forHTTPHeaderField: "Range") == nil {
            request.setValue(rangeHeader, forHTTPHeaderField: "Range")
        }

        let handler = ProxyFetchHandler(
            proxyPrefix: proxyPrefix,
            headOnly: headOnly,
            targetIsPlaylist: target.pathExtension.lowercased() == "m3u8",
            connection: connection
        )
        activeFetches[ObjectIdentifier(connection)] = handler
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(
            configuration: configuration,
            delegate: handler,
            delegateQueue: nil
        )
        handler.session = session
        let task = session.dataTask(with: request)
        handler.task = task
        task.resume()
    }

    nonisolated static func rewritePlaylist(_ playlist: String, base: URL?, prefix: String) -> String {
        var output: [String] = []
        for line in playlist.components(separatedBy: "\n") {
            output.append(rewriteLine(line, base: base, prefix: prefix))
        }
        return output.joined(separator: "\n")
    }

    private nonisolated static func rewriteLine(_ line: String, base: URL?, prefix: String) -> String {
        guard !prefix.isEmpty else { return line }
        if line.hasPrefix("#") {
            return rewriteURIAttributes(in: line, base: base, prefix: prefix)
        }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("http://127.0.0.1") else { return line }
        guard let resolved = resolve(trimmed, base: base) else { return line }
        return line.replacingOccurrences(of: trimmed, with: proxyURLString(for: resolved, prefix: prefix))
    }

    private nonisolated static func rewriteURIAttributes(in line: String, base: URL?, prefix: String) -> String {
        // Indices stay in the immutable input string; mutating a copy while
        // keeping its indices would invalidate them.
        var output = ""
        var cursor = line.startIndex
        while let uriRange = line.range(of: "URI=\"", range: cursor..<line.endIndex) {
            let valueStart = uriRange.upperBound
            guard let closingQuote = line[valueStart...].firstIndex(of: "\"") else {
                output += line[cursor...]
                return output
            }
            let value = String(line[valueStart..<closingQuote])
            output += line[cursor..<valueStart]
            if !value.hasPrefix("http://127.0.0.1"), let resolved = resolve(value, base: base) {
                output += proxyURLString(for: resolved, prefix: prefix)
            } else {
                output += value
            }
            cursor = closingQuote
        }
        output += line[cursor...]
        return output
    }

    private nonisolated static func resolve(_ uri: String, base: URL?) -> URL? {
        if let absolute = URL(string: uri), absolute.scheme == "http" || absolute.scheme == "https" {
            return absolute
        }
        guard let base, let relative = URL(string: uri, relativeTo: base)?.absoluteURL else { return nil }
        return relative
    }

    private nonisolated static func proxyURLString(for url: URL, prefix: String) -> String {
        let encoded = Data(url.absoluteString.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let pathExtension = url.pathExtension
        let fileComponent = pathExtension.isEmpty ? "stream" : "stream.\(pathExtension)"
        return "\(prefix)\(fileComponent)?u=\(encoded)"
    }

    private func sendSimple(status: String, on connection: NWConnection) {
        let head = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .idempotent)
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
    }
}

// Streams one upstream response into the player connection. Small playlists are
// buffered for rewriting; everything else passes through chunk by chunk so
// progressive files are never held in memory.
private final class ProxyFetchHandler: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    var session: URLSession?
    var task: URLSessionDataTask?

    private let proxyPrefix: String
    private let headOnly: Bool
    private let targetIsPlaylist: Bool
    private let connection: NWConnection

    private let lock = NSLock()
    private var buffer = Data()
    private var isPlaylist = false
    private var responseStatus = 200
    private var responseHeaders: [String: String] = [:]
    private var headSent = false
    private var baseURL: URL?

    init(
        proxyPrefix: String,
        headOnly: Bool,
        targetIsPlaylist: Bool,
        connection: NWConnection
    ) {
        self.proxyPrefix = proxyPrefix
        self.headOnly = headOnly
        self.targetIsPlaylist = targetIsPlaylist
        self.connection = connection
    }

    @MainActor func cancel() {
        task?.cancel()
        session?.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        if let http = response as? HTTPURLResponse {
            responseStatus = http.statusCode
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                guard let name = key as? String, let value = value as? String else { continue }
                headers[name.lowercased()] = value
            }
            responseHeaders = headers
        }
        baseURL = response.url
        let contentType = responseHeaders["content-type"]?.lowercased() ?? ""
        isPlaylist = targetIsPlaylist
            || response.url?.pathExtension.lowercased() == "m3u8"
            || contentType.contains("mpegurl")
            || contentType.contains("m3u8")
        headSent = false
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        if isPlaylist {
            buffer.append(data)
            lock.unlock()
            return
        }
        let sendHead = !headSent
        headSent = true
        let head = sendHead ? responseHead(includeContentLength: true) : nil
        lock.unlock()
        if let head {
            connection.send(content: head, completion: .idempotent)
        }
        if !headOnly {
            connection.send(content: data, completion: .idempotent)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let playlistMode = isPlaylist
        let buffered = buffer
        let alreadySentHead = headSent
        lock.unlock()

        if let error, (error as NSError).domain == NSURLErrorDomain, (error as NSError).code != NSURLErrorCancelled {
            if !alreadySentHead {
                sendSimpleError(status: "502 Bad Gateway")
            }
        } else if playlistMode, let playlist = String(data: buffered, encoding: .utf8) {
            let rewritten = HLSProxyServer.rewritePlaylist(playlist, base: baseURL, prefix: proxyPrefix)
            var body = Data(rewritten.utf8)
            if headOnly { body = Data() }
            var head = "HTTP/1.1 \(responseStatus) \(statusText(responseStatus))\r\n"
            head += "Content-Type: application/vnd.apple.mpegurl\r\n"
            head += "Content-Length: \(body.count)\r\n"
            head += "Connection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + body, completion: .idempotent)
        } else if !alreadySentHead {
            if let head = responseHead(includeContentLength: true) {
                connection.send(content: head, completion: .idempotent)
            }
        }
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [connection] _ in
            connection.cancel()
        })
        session.invalidateAndCancel()
    }

    private func responseHead(includeContentLength: Bool) -> Data? {
        lock.lock()
        let status = responseStatus
        let headers = responseHeaders
        lock.unlock()
        var head = "HTTP/1.1 \(status) \(statusText(status))\r\n"
        if let contentType = headers["content-type"] {
            head += "Content-Type: \(contentType)\r\n"
        }
        if includeContentLength, let length = headers["content-length"] {
            head += "Content-Length: \(length)\r\n"
        }
        if let contentRange = headers["content-range"] {
            head += "Content-Range: \(contentRange)\r\n"
        }
        if headers["accept-ranges"] != nil {
            head += "Accept-Ranges: bytes\r\n"
        }
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8)
    }

    private func sendSimpleError(status: String) {
        let head = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .idempotent)
    }

    private func statusText(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 304: return "Not Modified"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 416: return "Range Not Satisfiable"
        default: return "Response"
        }
    }
}
