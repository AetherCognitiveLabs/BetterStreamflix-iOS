import CryptoKit
import Foundation

struct UserProfile: Codable, Identifiable, Hashable, Sendable {
    static let defaultID = "default"

    var id: String
    var displayName: String
    var avatarSymbol: String
    var isKids: Bool = false
    /// Highest allowed age rating for Kids profiles (e.g. 6, 12); nil = no ceiling.
    var maxAgeRating: Int?
    var pinHash: String?
    var createdAt = Date()
    var updatedAt = Date()
}

/// Local profiles. Each profile keeps its own library (watchlist, history,
/// progress) in a separate directory; the default profile uses the original one.
@MainActor
final class ProfileStore: ObservableObject {
    static let shared = ProfileStore()
    static let kidsAgeOptions = [0, 6, 12, 16]

    private static let profilesKey = "profiles.list.v1"
    private static let activeKey = "profiles.activeID"

    @Published private(set) var profiles: [UserProfile] = []
    @Published private(set) var activeProfileID: String

    var activeProfile: UserProfile {
        profiles.first { $0.id == activeProfileID } ?? profiles[0]
    }

    private init() {
        activeProfileID = Self.persistedActiveID()
        if let data = UserDefaults.standard.data(forKey: Self.profilesKey),
           let stored = try? JSONDecoder().decode([UserProfile].self, from: data), !stored.isEmpty {
            profiles = stored
        } else {
            profiles = [UserProfile(id: UserProfile.defaultID, displayName: "Main", avatarSymbol: "person.crop.circle.fill")]
        }
        if !profiles.contains(where: { $0.id == activeProfileID }) { activeProfileID = profiles[0].id }
    }

    nonisolated static func persistedActiveID() -> String {
        UserDefaults.standard.string(forKey: activeKey) ?? UserProfile.defaultID
    }

    nonisolated static func libraryDirectory(for profileID: String) -> URL? {
        guard profileID != UserProfile.defaultID else { return nil }
        return LibraryStore.defaultDirectory()
            .appending(path: "profiles", directoryHint: .isDirectory)
            .appending(path: profileID, directoryHint: .isDirectory)
    }

    @discardableResult
    func create(name: String, isKids: Bool) -> UserProfile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = UserProfile(
            id: UUID().uuidString.lowercased(),
            displayName: trimmed.isEmpty ? (isKids ? "Kids" : "Profile \(profiles.count + 1)") : trimmed,
            avatarSymbol: isKids ? "face.smiling.inverse" : "person.crop.circle.fill",
            isKids: isKids,
            maxAgeRating: isKids ? 12 : nil
        )
        profiles.append(profile)
        save()
        return profile
    }

    func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id) { $0.displayName = trimmed }
    }

    func setKids(_ id: String, _ isKids: Bool) {
        update(id) {
            $0.isKids = isKids
            $0.maxAgeRating = isKids ? ($0.maxAgeRating ?? 12) : nil
            $0.avatarSymbol = isKids ? "face.smiling.inverse" : "person.crop.circle.fill"
        }
    }

    func setMaxAgeRating(_ id: String, _ age: Int?) { update(id) { $0.maxAgeRating = age } }

    func setPIN(_ id: String, _ pin: String?) {
        update(id) { profile in profile.pinHash = pin.flatMap { $0.isEmpty ? nil : Self.hash(pin: $0, profileID: id) } }
    }

    func verifyPIN(_ id: String, _ pin: String) -> Bool {
        guard let profile = profiles.first(where: { $0.id == id }), let hash = profile.pinHash else { return true }
        return Self.hash(pin: pin, profileID: id) == hash
    }

    /// Leaving a Kids profile requires the target's PIN when one is set.
    func requiresPIN(toSwitchTo id: String) -> Bool {
        profiles.first { $0.id == id }?.pinHash != nil
    }

    func delete(_ id: String, library: LibraryStore) {
        guard id != UserProfile.defaultID else { return }
        if activeProfileID == id { switchTo(UserProfile.defaultID, library: library) }
        profiles.removeAll { $0.id == id }
        if let directory = Self.libraryDirectory(for: id) { try? FileManager.default.removeItem(at: directory) }
        save()
    }

    func switchTo(_ id: String, library: LibraryStore) {
        guard profiles.contains(where: { $0.id == id }), id != activeProfileID else { return }
        activeProfileID = id
        UserDefaults.standard.set(id, forKey: Self.activeKey)
        library.switchDirectory(Self.libraryDirectory(for: id))
        CloudSyncManager.shared.reloadForActiveProfile()
    }

    private func update(_ id: String, _ change: (inout UserProfile) -> Void) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        change(&profiles[index])
        profiles[index].updatedAt = Date()
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(profiles) { UserDefaults.standard.set(data, forKey: Self.profilesKey) }
    }

    private static func hash(pin: String, profileID: String) -> String {
        SHA256.hash(data: Data("\(profileID):\(pin)".utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Kids content gate ported from Android's ParentalControlUtils: titles whose
/// genres are mature (by name or TMDB genre ID) are hidden on Kids profiles.
enum KidsContentFilter {
    private static let matureKeywords = [
        "horror", "terror", "thriller", "erotic", "erótica", "erotica", "adult", "adulto", "xxx",
        "18+", "+18", "nc-17", "war", "guerra", "belica", "bélica", "crime", "crimen", "krimi",
        "slasher", "gore", "suspense", "violence", "violencia", "softcore", "porn"
    ]
    private static let matureTMDBGenreIDs: Set<String> = ["27", "53", "80", "10752", "37"]

    @MainActor static var isActive: Bool { ProfileStore.shared.activeProfile.isKids }

    static func permits(_ item: MediaItem) -> Bool {
        !item.genres.contains { genre in
            let name = genre.name.lowercased()
            return matureTMDBGenreIDs.contains(genre.id) || matureKeywords.contains { name.contains($0) }
        }
    }

    @MainActor static func apply(_ items: [MediaItem]) -> [MediaItem] {
        isActive ? items.filter(permits) : items
    }

    static func permits(_ title: TrendingTitle) -> Bool {
        !title.genreNames.contains { name in
            let lowered = name.lowercased()
            return matureKeywords.contains { lowered.contains($0) }
        }
    }

    @MainActor static func apply(_ titles: [TrendingTitle]) -> [TrendingTitle] {
        isActive ? titles.filter(permits) : titles
    }

    @MainActor static func apply(_ shelves: [MediaShelf]) -> [MediaShelf] {
        guard isActive else { return shelves }
        return shelves.compactMap { shelf in
            let items = shelf.items.filter(permits)
            return items.isEmpty ? nil : MediaShelf(title: shelf.title, items: items)
        }
    }
}
