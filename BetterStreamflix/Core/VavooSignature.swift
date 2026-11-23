import Foundation

/// Vavoo's MediaHub resolve engines; each expects its own user agent and
/// signature header.
enum VavooMediaEngine: Sendable {
    case mediaHubMX, mediaURL

    var prefix: String { self == .mediaHubMX ? "mediahubmx" : "mediaurl" }
    var userAgent: String { self == .mediaHubMX ? "MediaHubMX/2" : "MediaUrl/2" }
    var signatureHeader: String { "\(prefix)-signature" }
}

/// Short-lived `addonSig` session used when the token-free geil.to mirror is
/// unavailable: VYPN app ping (1.9.2, then 1.4.1), then the legacy Vavoo ping.
actor VavooAddonSignature {
    struct Signature: Sendable {
        let value: String
        let profile: String
        let createdAt: Date
    }

    static let shared = VavooAddonSignature()

    private static let ttl: TimeInterval = 90
    private static let pingUserAgent = "electron-fetch/1.0 electron (+https://github.com/arantes555/electron-fetch)"
    private static let apiUserAgent = "okhttp/4.11.0"
    private var cached: Signature?
    private var inFlight: Task<Signature?, Never>?

    func invalidate() { cached = nil }

    func current(force: Bool = false) async -> Signature? {
        if !force, let cached, Date().timeIntervalSince(cached.createdAt) < Self.ttl { return cached }
        if let inFlight { return await inFlight.value }
        let task = Task { await Self.requestSignature() }
        inFlight = task
        let signature = await task.value
        inFlight = nil
        cached = signature
        return signature
    }

    private static func requestSignature() async -> Signature? {
        for version in ["1.9.2", "1.4.1"] {
            if let value = await ping(
                "https://www.vypn.net/api/app/ping",
                body: vypnBody(version: version),
                headers: ["User-Agent": pingUserAgent, "Accept-Language": "de"]
            ) {
                return Signature(value: value, profile: version, createdAt: Date())
            }
        }
        if let value = await ping("https://www.vavoo.tv/api/app/ping", body: legacyBody(), headers: ["User-Agent": apiUserAgent]) {
            return Signature(value: value, profile: "vavoo-3.1.20", createdAt: Date())
        }
        return nil
    }

    private static func ping(_ endpoint: String, body: [String: Any], headers: [String: String]) async -> String? {
        guard let url = URL(string: endpoint), let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let signature = object["addonSig"] as? String, !signature.isEmpty else { return nil }
        return signature
    }

    private static func uniqueID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16))
    }

    private static func vypnBody(version: String) -> [String: Any] {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return [
            "token": "", "reason": "app-focus", "locale": "de", "theme": "dark",
            "metadata": [
                "device": ["type": "phone", "uniqueId": uniqueID()],
                "os": ["name": "android", "version": "14", "abis": ["arm64-v8a"], "host": "android"],
                "app": ["platform": "android"],
                "version": ["package": "net.vypn.app", "binary": version, "js": version]
            ],
            "appFocusTime": 0, "playerActive": false, "playDuration": 0, "devMode": false,
            "hasAddon": true, "castConnected": false, "package": "net.vypn.app", "version": version,
            "process": "app", "firstAppStart": now - 86_400_000, "lastAppStart": now,
            "ipLocation": NSNull(), "adblockEnabled": true,
            "migrationApplied": false, "migrationTargetInstalled": false,
            "proxy": ["supported": ["ss"], "engine": "Mu", "ssVersion": "2022", "enabled": false, "autoServer": true, "id": ""],
            "iap": ["supported": false, "error": ""]
        ]
    }

    private static func legacyBody() -> [String: Any] {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return [
            "token": "", "reason": "app-blur", "locale": "de", "theme": "dark",
            "metadata": [
                "device": ["type": "Handset", "brand": "google", "model": "Nexus", "name": "21081111RG", "uniqueId": uniqueID()],
                "os": ["name": "android", "version": "7.1.2", "abis": ["arm64-v8a", "armeabi-v7a", "armeabi"], "host": "android"],
                "app": [
                    "platform": "android", "version": "3.1.20", "buildId": "289515000", "engine": "hbc85",
                    "signatures": ["6e8a975e3cbf07d5de823a760d4c2547f86c1403105020adee5de67ac510999e"],
                    "installer": "app.revanced.manager.flutter"
                ],
                "version": ["package": "tv.vavoo.app", "binary": "3.1.20", "js": "3.1.20"]
            ],
            "appFocusTime": 0, "playerActive": false, "playDuration": 0, "devMode": false,
            "hasAddon": true, "castConnected": false, "package": "tv.vavoo.app", "version": "3.1.20",
            "process": "app", "firstAppStart": now, "lastAppStart": now, "ipLocation": "",
            "adblockEnabled": true,
            "proxy": ["supported": ["ss", "openvpn"], "engine": "ss", "ssVersion": 1, "enabled": true, "autoServer": true, "id": "pl-waw"],
            "iap": ["supported": false]
        ]
    }
}
