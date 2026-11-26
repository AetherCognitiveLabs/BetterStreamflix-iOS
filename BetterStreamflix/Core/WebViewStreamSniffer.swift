import Foundation
import UIKit
import WebKit

/// Last-resort stream extraction through a real offscreen WKWebView. Hoster
/// embed pages increasingly hide the video URL behind obfuscated JS that only
/// runs in a browser (VOE mirrors, mixdrop popunder chains, anti-bot gates).
/// The sniffer loads the page with media autoplay enabled, hooks xhr/fetch/
/// performance entries plus every <video> element, and reports the first
/// m3u8/mp4 the player actually requests — the same trick that worked for
/// SerienStream-iOS.
@MainActor
final class WebViewStreamSniffer: NSObject {
    static let shared = WebViewStreamSniffer()

    /// One sniff at a time: embed pages are heavy and parallel webviews burn
    /// memory for no benefit.
    private var activeTask: Task<PlaybackSource?, Never>?

    struct Result {
        let url: URL
        let userAgent: String
        let referer: URL
    }

    private static let hookScript = """
    (function() {
        if (window.__bsfSniffed) return;
        window.__bsfSniffed = [];
        window.__bsfPush = function(u) {
            try {
                if (!u || typeof u !== 'string') return;
                var clean = u.replace(/\\\\\\//g, '/');
                if (!/(m3u8|\\.mp4)(\\?|#|$)/i.test(clean)) return;
                if (window.__bsfSniffed.indexOf(clean) === -1) window.__bsfSniffed.push(clean);
            } catch (e) {}
        };
        var scan = function(u) { window.__bsfPush(u); };
        var origOpen = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function(method, url) {
            scan(String(url));
            return origOpen.apply(this, arguments);
        };
        var origFetch = window.fetch;
        if (origFetch) {
            window.fetch = function(input) {
                try { scan(typeof input === 'string' ? input : input.url); } catch (e) {}
                return origFetch.apply(this, arguments);
            };
        }
        var origSetAttr = HTMLMediaElement.prototype.setAttribute;
        HTMLMediaElement.prototype.setAttribute = function(name, value) {
            if (name === 'src') scan(String(value));
            return origSetAttr.apply(this, arguments);
        };
        setInterval(function() {
            try {
                performance.getEntriesByType('resource').forEach(function(e) { scan(e.name); });
                document.querySelectorAll('video, video source, source').forEach(function(el) {
                    if (el.src) scan(el.src);
                });
                document.querySelectorAll('video').forEach(function(v) {
                    if (v.currentSrc) scan(v.currentSrc);
                });
                document.querySelectorAll('button, [class*=play], [id*=play], .vjs-big-play-button').forEach(function(b) {
                    if (!b.__bsfClicked) { b.__bsfClicked = true; try { b.click(); } catch (e) {} }
                });
                document.querySelectorAll('video').forEach(function(v) {
                    if (v.paused) { try { var p = v.play(); if (p && p.catch) p.catch(function(){}); } catch (e) {} }
                });
            } catch (e) {}
        }, 700);
    })();
    true;
    """

    /// Loads the embed in a throwaway offscreen webview and watches for video
    /// requests for up to `timeout` seconds. Returns nil when nothing surfaces.
    func sniff(_ url: URL, referer: URL?, timeout: TimeInterval = 16) async -> PlaybackSource? {
        if let activeTask { return await activeTask.value }
        let task = Task<PlaybackSource?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.runSniff(url, referer: referer, timeout: timeout)
        }
        activeTask = task
        let value = await task.value
        activeTask = nil
        return value
    }

    private func runSniff(_ url: URL, referer: URL?, timeout: TimeInterval) async -> PlaybackSource? {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = preferences
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.hookScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 300), configuration: configuration)
        let desktopUA = HTTPClient.desktopUserAgent
        webView.customUserAgent = desktopUA
        // Offscreen but attached: some players check visibility/attachment.
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = scene.windows.first {
            webView.frame = CGRect(x: -2000, y: -2000, width: 390, height: 300)
            window.addSubview(webView)
        }
        defer { webView.removeFromSuperview() }

        var request = URLRequest(url: url)
        if let referer { request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
        webView.load(request)

        let deadline = Date().addingTimeInterval(timeout)
        var found: String?
        while Date() < deadline {
            if Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(600))
            let raw = try? await webView.evaluateJavaScript("window.__bsfSniffed ? window.__bsfSniffed.join('\\n') : ''")
            if let list = raw as? String {
                let candidates = list.split(separator: "\n").map(String.init)
                // Prefer HLS; mp4 progressive is the fallback.
                found = candidates.first { $0.lowercased().contains(".m3u8") } ?? candidates.first
                if found != nil { break }
            }
        }
        guard let rawFound = found,
              let source = URL(string: rawFound.hasPrefix("//") ? "https:" + rawFound : rawFound) else { return nil }

        let finalReferer = webView.url ?? url
        var headers = [
            "User-Agent": desktopUA,
            "Referer": finalReferer.absoluteString,
            "Origin": finalReferer.origin,
        ]
        // Hoster CDNs validate the clearance/session cookies the WebView earned.
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let host = source.host?.lowercased() ?? ""
        let jar = cookies.filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return host == domain || host.hasSuffix("." + domain) || domain.hasSuffix(host)
        }
        if !jar.isEmpty {
            headers["Cookie"] = jar.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }
        return PlaybackSource(url: source, headers: headers, subtitles: [], preferredPeakBitRate: nil)
    }
}
