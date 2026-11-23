import Foundation

/// Follows a provider's default domain to wherever it currently redirects and
/// persists that as a base-URL override, ported from BetterStreamflix
/// Android's ProviderDomainUpdater/DomainRedirectChecker. Parked or for-sale
/// landing pages are rejected so a dead domain never replaces a live one.
actor ProviderDomainUpdater {
    static let shared = ProviderDomainUpdater()

    enum Outcome: Sendable, Equatable {
        case updated(URL)
        case unchanged
        case failed(String)
    }

    /// Providers that hop domains and read their base URL through `baseURL(for:default:)`.
    static let defaults: [String: URL] = [
        "kellerkino": URL(string: "https://www.kellerkino.com/")!,
        "shahid4u": URL(string: "https://shahidd4u.day/")!,
    ]

    private static let parkingHosts = ["sedo.com", "godaddy.com", "domainmarket.com", "afternic.com", "hugedomains.com", "dan.com"]
    private static let parkingMarkers = [
        "domain is for sale", "buy this domain", "this domain is parked", "parked domain",
        "sedo parking", "related searches", "hugedomains",
    ]
    private static let minimumInterval: TimeInterval = 30 * 60

    private var lastChecked: [String: Date] = [:]

    private static func key(_ providerID: String) -> String { "providerDomainOverride.\(providerID)" }

    /// The persisted override for `providerID`, or `fallback`.
    nonisolated static func baseURL(for providerID: String, default fallback: URL) -> URL {
        guard let raw = UserDefaults.standard.string(forKey: key(providerID)), let url = URL(string: raw) else {
            return fallback
        }
        return url
    }

    nonisolated static func reset(_ providerID: String) {
        UserDefaults.standard.removeObject(forKey: key(providerID))
    }

    /// Re-checks where the provider's domain lands now. Throttled per provider.
    @discardableResult
    func update(_ providerID: String, force: Bool = false) async -> Outcome {
        guard let fallback = Self.defaults[providerID] else { return .failed("Provider has no configurable domain") }
        let now = Date()
        if !force, let last = lastChecked[providerID], now.timeIntervalSince(last) < Self.minimumInterval {
            return .unchanged
        }
        lastChecked[providerID] = now
        let start = Self.baseURL(for: providerID, default: fallback)
        do {
            let response = try await HosterHTTP.shared.get(start)
            // A Cloudflare challenge still proves the domain is alive.
            guard (200...299).contains(response.statusCode)
                || CloudflareResolver.isChallenge(statusCode: response.statusCode, html: response.text) else {
                return .failed("HTTP \(response.statusCode)")
            }
            guard let host = response.url.host?.lowercased() else { return .failed("No host") }
            let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            if Self.parkingHosts.contains(where: { bare == $0 || bare.hasSuffix(".\($0)") }) {
                return .failed("Redirect landed on parking host \(bare)")
            }
            let body = response.text.lowercased()
            if Self.parkingMarkers.contains(where: body.contains) {
                return .failed("Domain looks parked")
            }
            guard host != start.host?.lowercased(),
                  let landed = URL(string: "\(response.url.scheme ?? "https")://\(host)/") else { return .unchanged }
            UserDefaults.standard.set(landed.absoluteString, forKey: Self.key(providerID))
            return .updated(landed)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
