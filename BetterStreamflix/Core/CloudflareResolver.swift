import Foundation
import UIKit
import WebKit

/// Result of letting a real WebKit view clear a Cloudflare challenge. The
/// clearance cookies only validate together with the WebView's user agent, so
/// follow-up URLSession requests must send both.
struct CloudflareClearance: Sendable {
    let finalURL: URL
    let html: String
    let cookies: [String: String]
    let userAgent: String
    let obtainedAt: Date

    var cfClearance: String? { cookies["cf_clearance"] }

    var cookieHeader: String {
        cookies.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    /// Headers that make a URLSession request look like the WebView that passed.
    var headers: [String: String] {
        var result = ["User-Agent": userAgent]
        if !cookies.isEmpty { result["Cookie"] = cookieHeader }
        return result
    }
}

/// Offscreen WKWebView bypass for Cloudflare 403 / "Just a moment" / Turnstile
/// pages, ported from BetterStreamflix Android's CloudflareDocumentFetch.
/// Plain HTTP is always tried first; the WebView only runs when that answers
/// with a challenge, and its clearance is cached per host for reuse.
@MainActor
final class CloudflareResolver: NSObject {
    static let shared = CloudflareResolver()

    /// cf_clearance usually lives 30 minutes; refresh a bit earlier.
    private static let clearanceLifetime: TimeInterval = 25 * 60
    private var clearances: [String: CloudflareClearance] = [:]
    private var inFlight: [String: Task<CloudflareClearance, Error>] = [:]

    // MARK: Challenge detection

    nonisolated static func isChallenge(statusCode: Int, html: String) -> Bool {
        if html.contains("Just a moment")
            || html.contains("cf-browser-verification")
            || html.contains("Checking your browser")
            || html.contains("cf-mitigated")
            || html.contains("/cdn-cgi/challenge")
            || html.contains("challenge-platform")
            || html.contains("challenges.cloudflare.com/turnstile")
            || html.localizedCaseInsensitiveContains("Verify you are human")
            || html.contains("Attention Required! | Cloudflare")
            || html.contains("<title>Redirecting...</title>") {
            return true
        }
        return statusCode == 403 || statusCode == 503
    }

    nonisolated static func defaultUsable(_ html: String) -> Bool {
        html.contains("class=\"") && html.count > 20_000
    }

    // MARK: Lazy fetch helpers

    /// Page HTML through plain HTTP, falling back to the WebView only when the
    /// plain response is a Cloudflare challenge or 403/503.
    nonisolated static func page(
        _ url: URL,
        referer: URL? = nil,
        headers: [String: String] = [:],
        isUsable: @escaping @Sendable (String) -> Bool = defaultUsable
    ) async throws -> String {
        let response = try await get(url, referer: referer, headers: headers, acceptsJSON: false, isUsable: isUsable)
        return response.text
    }

    /// JSON through plain HTTP with the same lazy clearance fallback.
    nonisolated static func json(
        _ url: URL,
        referer: URL? = nil,
        headers: [String: String] = [:]
    ) async throws -> Any {
        let response = try await get(url, referer: referer, headers: headers, acceptsJSON: true) { html in
            let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
        }
        guard (200...299).contains(response.statusCode) else {
            throw AppError.providerUnavailable("HTTP \(response.statusCode)")
        }
        return try JSONSerialization.jsonObject(with: response.data, options: [.fragmentsAllowed])
    }

    /// A raw response that is only routed through the WebView on a challenge.
    /// When the cleared cookies still don't satisfy URLSession, the WebView's
    /// own rendered document is returned instead.
    nonisolated static func get(
        _ url: URL,
        referer: URL? = nil,
        headers: [String: String] = [:],
        acceptsJSON: Bool = false,
        isUsable: @escaping @Sendable (String) -> Bool = defaultUsable
    ) async throws -> HosterResponse {
        var merged = headers
        if let cached = await shared.cachedClearance(for: url) {
            merged.merge(cached.headers) { current, _ in current }
        }
        let first = try await HosterHTTP.shared.get(url, referer: referer, headers: merged, acceptsJSON: acceptsJSON)
        guard isChallenge(statusCode: first.statusCode, html: first.text), !isUsable(first.text) else {
            return first
        }

        let clearance = try await shared.clearance(for: url, isUsable: isUsable)
        var retryHeaders = headers
        retryHeaders.merge(clearance.headers) { _, cleared in cleared }
        let retry = try await HosterHTTP.shared.get(url, referer: referer, headers: retryHeaders, acceptsJSON: acceptsJSON)
        if !isChallenge(statusCode: retry.statusCode, html: retry.text) || isUsable(retry.text) {
            return retry
        }
        guard isUsable(clearance.html) else { throw AppError.providerUnavailable("Cloudflare challenge not cleared") }
        return HosterResponse(
            data: Data(clearance.html.utf8),
            url: clearance.finalURL,
            statusCode: 200,
            headers: [:]
        )
    }

    // MARK: Clearance

    func cachedClearance(for url: URL) -> CloudflareClearance? {
        guard let host = Self.hostKey(url), let cached = clearances[host] else { return nil }
        guard Date().timeIntervalSince(cached.obtainedAt) < Self.clearanceLifetime else {
            clearances[host] = nil
            return nil
        }
        return cached
    }

    func invalidate(_ url: URL) {
        guard let host = Self.hostKey(url) else { return }
        clearances[host] = nil
    }

    /// Renders `url` in an offscreen WebView until the challenge clears, then
    /// caches the cookies + UA for the host. Concurrent callers share one run.
    func clearance(
        for url: URL,
        timeout: TimeInterval = 25,
        isUsable: @escaping @Sendable (String) -> Bool = defaultUsable
    ) async throws -> CloudflareClearance {
        let host = Self.hostKey(url) ?? url.absoluteString
        if let running = inFlight[host] { return try await running.value }
        let task = Task { @MainActor in
            try await self.render(url, timeout: timeout, isUsable: isUsable)
        }
        inFlight[host] = task
        defer { inFlight[host] = nil }
        let result = try await task.value
        clearances[host] = result
        Self.store(result, for: url)
        return result
    }

    private func render(
        _ url: URL,
        timeout: TimeInterval,
        isUsable: @Sendable (String) -> Bool
    ) async throws -> CloudflareClearance {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let webView = WKWebView(frame: CGRect(x: -2_000, y: -2_000, width: 1_024, height: 768), configuration: configuration)
        webView.alpha = 0.01
        webView.isUserInteractionEnabled = false
        // Timers and Turnstile only run reliably for a view in a window.
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first
        window?.addSubview(webView)
        defer {
            webView.stopLoading()
            webView.removeFromSuperview()
        }

        webView.load(URLRequest(url: url))
        let deadline = Date().addingTimeInterval(timeout)
        let cookieStore = configuration.websiteDataStore.httpCookieStore
        let host = Self.hostKey(url) ?? ""

        while Date() < deadline {
            try await Task.sleep(nanoseconds: 700_000_000)
            try Task.checkCancellation()
            // Non-HTML answers (JSON APIs) are wrapped in a viewer document by WebKit.
            let html = (try? await webView.evaluateJavaScript(
                "(document.contentType || '').indexOf('html') >= 0 ? document.documentElement.outerHTML : (document.body ? document.body.innerText : '')"
            ) as? String) ?? ""
            let title = (try? await webView.evaluateJavaScript("document.title") as? String) ?? ""
            let cookies = await cookieStore.allCookies().filter { cookie in
                let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
                return host.hasSuffix(domain) || domain.hasSuffix(host)
            }
            let challenged = title.contains("Just a moment")
                || title.contains("Attention Required")
                || Self.isChallenge(statusCode: 200, html: html)
            let cleared = cookies.contains { $0.name == "cf_clearance" }
            guard !html.isEmpty, (cleared && !challenged) || isUsable(html) else {
                continue
            }
            let userAgent = (try? await webView.evaluateJavaScript("navigator.userAgent") as? String)
                ?? HTTPClient.desktopUserAgent
            var jar: [String: String] = [:]
            for cookie in cookies { jar[cookie.name] = cookie.value }
            return CloudflareClearance(
                finalURL: webView.url ?? url,
                html: html,
                cookies: jar,
                userAgent: userAgent,
                obtainedAt: Date()
            )
        }
        throw AppError.providerUnavailable("Cloudflare challenge timed out")
    }

    /// Mirror the cleared cookies into the shared URLSession jar so hoster
    /// extractors following the provider page reuse them too.
    private static func store(_ clearance: CloudflareClearance, for url: URL) {
        guard let host = url.host else { return }
        for (name, value) in clearance.cookies {
            guard let cookie = HTTPCookie(properties: [
                .domain: host,
                .path: "/",
                .name: name,
                .value: value,
                .secure: "TRUE",
                .expires: Date().addingTimeInterval(clearanceLifetime),
            ]) else { continue }
            HosterHTTP.shared.cookieStorage.setCookie(cookie)
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }

    nonisolated private static func hostKey(_ url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
