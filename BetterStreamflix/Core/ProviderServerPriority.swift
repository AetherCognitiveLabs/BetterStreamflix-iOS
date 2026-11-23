import Foundation

/// Manual per-provider server pins, ported from BetterStreamflix Android's
/// ProviderServerPriority: pinned server names are tried before the rest of a
/// provider's candidates (an explicit preferred server still wins first).
enum ProviderServerPriority {
    static let maxPins = 8
    private static let storageKey = "providerServerPriority"

    static func pins(for providerID: String) -> [String] {
        load()[providerID] ?? []
    }

    static func isPinned(_ providerID: String, serverName: String) -> Bool {
        let key = normalized(serverName)
        return !key.isEmpty && pins(for: providerID).contains(key)
    }

    static func pin(_ providerID: String, serverName: String) {
        let key = normalized(serverName)
        guard !providerID.isEmpty, !key.isEmpty else { return }
        mutate(providerID) { list in
            list.removeAll { $0 == key }
            list.insert(key, at: 0)
            if list.count > maxPins { list.removeLast(list.count - maxPins) }
        }
    }

    static func unpin(_ providerID: String, serverName: String) {
        let key = normalized(serverName)
        mutate(providerID) { $0.removeAll { $0 == key } }
    }

    @discardableResult
    static func toggle(_ providerID: String, serverName: String) -> Bool {
        if isPinned(providerID, serverName: serverName) {
            unpin(providerID, serverName: serverName)
            return false
        }
        pin(providerID, serverName: serverName)
        return true
    }

    static func clear(_ providerID: String) {
        mutate(providerID) { $0.removeAll() }
    }

    /// Position of the candidate's server in its provider's pin list; unpinned sorts last.
    static func rank(_ candidate: PlaybackCandidate) -> Int {
        let key = normalized(candidate.preference.serverName)
        return pins(for: candidate.preference.providerID).firstIndex(of: key) ?? maxPins
    }

    /// Preferred server first, then pins in pin order, then the original order.
    static func apply(
        _ candidates: [PlaybackCandidate],
        providerID: String,
        preferredServerName: String? = nil
    ) -> [PlaybackCandidate] {
        guard candidates.count > 1 else { return candidates }
        let pins = pins(for: providerID)
        let preferred = preferredServerName.map(normalized) ?? ""
        guard !pins.isEmpty || !preferred.isEmpty else { return candidates }
        var remaining = candidates
        var head: [PlaybackCandidate] = []
        for key in ([preferred] + pins) where !key.isEmpty {
            if let index = remaining.firstIndex(where: { normalized($0.preference.serverName) == key }) {
                head.append(remaining.remove(at: index))
            }
        }
        return head + remaining
    }

    private static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func load() -> [String: [String]] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let value = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return value
    }

    private static func mutate(_ providerID: String, _ change: (inout [String]) -> Void) {
        var root = load()
        var list = root[providerID] ?? []
        change(&list)
        root[providerID] = list.isEmpty ? nil : list
        if let data = try? JSONEncoder().encode(root) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
