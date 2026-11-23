import Foundation

/// Per-provider circuit breaker, ported from BetterStreamflix Android's
/// ProviderHealth/ProviderSmoke: a provider that keeps failing is skipped for
/// a short cool-down so discovery doesn't wait on dead sites every time.
actor ProviderHealth {
    static let shared = ProviderHealth()

    /// Open the circuit after this many failures inside `failureWindow`.
    static let failureThreshold = 3
    static let failureWindow: TimeInterval = 10 * 60
    static let openDuration: TimeInterval = 2 * 60

    /// Providers known to be dead or unusable; they are always skipped.
    static let quarantinedIDs: Set<String> = []

    private struct Window {
        var start: Date
        var failures: Int
        var openUntil: Date?
    }

    private var windows: [String: Window] = [:]

    func isAvailable(_ providerID: String, now: Date = Date()) -> Bool {
        if Self.quarantinedIDs.contains(providerID) { return false }
        guard let openUntil = windows[providerID]?.openUntil else { return true }
        if now < openUntil { return false }
        // Half-open: let the next lookup through and start a fresh window.
        windows[providerID] = nil
        return true
    }

    func recordSuccess(_ providerID: String) {
        windows[providerID] = nil
    }

    func recordFailure(_ providerID: String, now: Date = Date()) {
        var window = windows[providerID] ?? Window(start: now, failures: 0, openUntil: nil)
        if now.timeIntervalSince(window.start) > Self.failureWindow {
            window = Window(start: now, failures: 0, openUntil: nil)
        }
        window.failures += 1
        if window.failures >= Self.failureThreshold {
            window.openUntil = now.addingTimeInterval(Self.openDuration)
            // A provider that keeps failing may have moved to a new domain.
            if ProviderDomainUpdater.defaults[providerID] != nil {
                Task { await ProviderDomainUpdater.shared.update(providerID) }
            }
        }
        windows[providerID] = window
    }

    /// Providers currently skipped: quarantined or with an open circuit.
    func outageProviderIDs(now: Date = Date()) -> [String] {
        let open = windows.compactMap { id, window in
            window.openUntil.map { $0 > now } == true ? id : nil
        }
        return (Array(Self.quarantinedIDs) + open).sorted()
    }

    func failureCount(_ providerID: String) -> Int {
        windows[providerID]?.failures ?? 0
    }

    /// Runs a provider lookup through the breaker; cancellations don't count.
    nonisolated func guarded<Element: Sendable>(
        _ providerID: String,
        _ operation: () async throws -> [Element]
    ) async throws -> [Element] {
        guard await isAvailable(providerID) else { return [] }
        do {
            let result = try await operation()
            await recordSuccess(providerID)
            return result
        } catch {
            if !(error is CancellationError), !Task.isCancelled {
                await recordFailure(providerID)
            }
            throw error
        }
    }
}

/// Outage-notice policy ported from BetterStreamflix Android's
/// ProviderOutagePolicy (no UI here): an outage is relevant when the current
/// provider is down, or when enough providers are down at once to be severe.
/// Dismissing hides the notice for a cool-down.
enum ProviderOutagePolicy {
    enum Level: Sendable, Equatable {
        case none, watch, severe
    }

    static let severeThreshold = 3
    static let dismissCooldown: TimeInterval = 6 * 60 * 60
    private static let dismissKey = "providerOutageDismissedAt"

    static func level(outageIDs: [String]) -> Level {
        if outageIDs.isEmpty { return .none }
        return outageIDs.count >= severeThreshold ? .severe : .watch
    }

    /// The current provider when it is down; on a severe outage also the other enabled ones that are down.
    static func relevantOutageIDs(
        outageIDs: [String],
        currentProviderID: String?,
        enabledProviderIDs: Set<String> = []
    ) -> [String] {
        guard !outageIDs.isEmpty else { return [] }
        var result: [String] = []
        if let currentProviderID, outageIDs.contains(currentProviderID) { result.append(currentProviderID) }
        if level(outageIDs: outageIDs) == .severe {
            result += outageIDs.filter { $0 != currentProviderID && (enabledProviderIDs.isEmpty || enabledProviderIDs.contains($0)) }
        }
        return result
    }

    static func shouldShow(relevantIDs: [String], now: Date = Date()) -> Bool {
        guard !relevantIDs.isEmpty else { return false }
        let dismissedAt = UserDefaults.standard.double(forKey: dismissKey)
        guard dismissedAt > 0 else { return true }
        return now.timeIntervalSince1970 - dismissedAt >= dismissCooldown
    }

    static func dismiss(now: Date = Date()) {
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: dismissKey)
    }

    static func clearDismiss() {
        UserDefaults.standard.removeObject(forKey: dismissKey)
    }
}
