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

    func failureCount(_ providerID: String) -> Int {
        windows[providerID]?.failures ?? 0
    }

    /// Runs a provider lookup through the breaker; cancellations don't count.
    nonisolated func guarded(
        _ providerID: String,
        _ operation: () async throws -> [PlaybackCandidate]
    ) async throws -> [PlaybackCandidate] {
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
