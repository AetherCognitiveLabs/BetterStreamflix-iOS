import Combine
import Foundation
import Network
import Security

/// One row of Android's Supabase `user_media_state` table (same column names,
/// so both apps can share a project).
struct CloudMediaState: Codable, Hashable, Sendable {
    var userID: String
    var provider: String
    var mediaType: String
    var mediaID: String
    var parentShowID: String?
    var parentShowTitle: String?
    var parentShowPoster: String?
    var parentShowBanner: String?
    var seasonID: String?
    var seasonNumber: Int?
    var seasonTitle: String?
    var seasonPoster: String?
    var episodeNumber: Int?
    var title = ""
    var poster: String?
    var banner: String?
    var isFavorite = false
    var favoritedAtMillis: Int64?
    var isWatched = false
    var watchedAtMillis: Int64?
    var lastEngagementAtMillis: Int64?
    var playbackPositionMillis: Int64?
    var durationMillis: Int64?
    var isWatching: Bool?
    var clientUpdatedAtMillis: Int64 = 0

    var key: String { [provider, mediaType, mediaID].joined(separator: "|") }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id", provider, mediaType = "media_type", mediaID = "media_id"
        case parentShowID = "parent_show_id", parentShowTitle = "parent_show_title"
        case parentShowPoster = "parent_show_poster", parentShowBanner = "parent_show_banner"
        case seasonID = "season_id", seasonNumber = "season_number", seasonTitle = "season_title"
        case seasonPoster = "season_poster", episodeNumber = "episode_number"
        case title, poster, banner
        case isFavorite = "is_favorite", favoritedAtMillis = "favorited_at_millis"
        case isWatched = "is_watched", watchedAtMillis = "watched_at_millis"
        case lastEngagementAtMillis = "last_engagement_at_millis"
        case playbackPositionMillis = "playback_position_millis", durationMillis = "duration_millis"
        case isWatching = "is_watching", clientUpdatedAtMillis = "client_updated_at_millis"
    }

    init(userID: String, provider: String, mediaType: String, mediaID: String) {
        self.userID = userID
        self.provider = provider
        self.mediaType = mediaType
        self.mediaID = mediaID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userID = try c.decodeIfPresent(String.self, forKey: .userID) ?? ""
        provider = try c.decode(String.self, forKey: .provider)
        mediaType = try c.decode(String.self, forKey: .mediaType)
        mediaID = try c.decode(String.self, forKey: .mediaID)
        parentShowID = try c.decodeIfPresent(String.self, forKey: .parentShowID)
        parentShowTitle = try c.decodeIfPresent(String.self, forKey: .parentShowTitle)
        parentShowPoster = try c.decodeIfPresent(String.self, forKey: .parentShowPoster)
        parentShowBanner = try c.decodeIfPresent(String.self, forKey: .parentShowBanner)
        seasonID = try c.decodeIfPresent(String.self, forKey: .seasonID)
        seasonNumber = try c.decodeIfPresent(Int.self, forKey: .seasonNumber)
        seasonTitle = try c.decodeIfPresent(String.self, forKey: .seasonTitle)
        seasonPoster = try c.decodeIfPresent(String.self, forKey: .seasonPoster)
        episodeNumber = try c.decodeIfPresent(Int.self, forKey: .episodeNumber)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        poster = try c.decodeIfPresent(String.self, forKey: .poster)
        banner = try c.decodeIfPresent(String.self, forKey: .banner)
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        favoritedAtMillis = try c.decodeIfPresent(Int64.self, forKey: .favoritedAtMillis)
        isWatched = try c.decodeIfPresent(Bool.self, forKey: .isWatched) ?? false
        watchedAtMillis = try c.decodeIfPresent(Int64.self, forKey: .watchedAtMillis)
        lastEngagementAtMillis = try c.decodeIfPresent(Int64.self, forKey: .lastEngagementAtMillis)
        playbackPositionMillis = try c.decodeIfPresent(Int64.self, forKey: .playbackPositionMillis)
        durationMillis = try c.decodeIfPresent(Int64.self, forKey: .durationMillis)
        isWatching = try c.decodeIfPresent(Bool.self, forKey: .isWatching)
        clientUpdatedAtMillis = try c.decodeIfPresent(Int64.self, forKey: .clientUpdatedAtMillis) ?? 0
    }

    /// Always writes every column (nulls included) like Android's `@EncodeDefault`,
    /// so bulk upserts send a uniform column set.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(userID, forKey: .userID)
        try c.encode(provider, forKey: .provider)
        try c.encode(mediaType, forKey: .mediaType)
        try c.encode(mediaID, forKey: .mediaID)
        try c.encode(parentShowID, forKey: .parentShowID)
        try c.encode(parentShowTitle, forKey: .parentShowTitle)
        try c.encode(parentShowPoster, forKey: .parentShowPoster)
        try c.encode(parentShowBanner, forKey: .parentShowBanner)
        try c.encode(seasonID, forKey: .seasonID)
        try c.encode(seasonNumber, forKey: .seasonNumber)
        try c.encode(seasonTitle, forKey: .seasonTitle)
        try c.encode(seasonPoster, forKey: .seasonPoster)
        try c.encode(episodeNumber, forKey: .episodeNumber)
        try c.encode(title, forKey: .title)
        try c.encode(poster, forKey: .poster)
        try c.encode(banner, forKey: .banner)
        try c.encode(isFavorite, forKey: .isFavorite)
        try c.encode(favoritedAtMillis, forKey: .favoritedAtMillis)
        try c.encode(isWatched, forKey: .isWatched)
        try c.encode(watchedAtMillis, forKey: .watchedAtMillis)
        try c.encode(lastEngagementAtMillis, forKey: .lastEngagementAtMillis)
        try c.encode(playbackPositionMillis, forKey: .playbackPositionMillis)
        try c.encode(durationMillis, forKey: .durationMillis)
        try c.encode(isWatching, forKey: .isWatching)
        try c.encode(clientUpdatedAtMillis, forKey: .clientUpdatedAtMillis)
    }

    fileprivate struct Signature: Equatable {
        let favorite: Bool
        let watched: Bool
        let positionSeconds: Int64
        let durationSeconds: Int64
    }

    fileprivate var signature: Signature {
        Signature(
            favorite: isFavorite,
            watched: isWatched,
            positionSeconds: (playbackPositionMillis ?? 0) / 1000,
            durationSeconds: (durationMillis ?? 0) / 1000
        )
    }

    /// Android `CloudSyncManager.mergeState`: newest write wins for favorite and
    /// watched, the latest engagement wins for resume position.
    static func merge(remote: CloudMediaState, local: CloudMediaState, at now: Int64) -> CloudMediaState {
        let localIsNewest = local.clientUpdatedAtMillis >= remote.clientUpdatedAtMillis
        let newest = localIsNewest ? local : remote
        let oldest = localIsNewest ? remote : local
        let history: CloudMediaState?
        if newest.isWatched && newest.lastEngagementAtMillis == nil {
            history = nil
        } else if let localAt = local.lastEngagementAtMillis {
            if let remoteAt = remote.lastEngagementAtMillis, remoteAt > localAt { history = remote } else { history = local }
        } else {
            history = remote.lastEngagementAtMillis != nil ? remote : nil
        }
        var merged = newest
        merged.parentShowID = newest.parentShowID ?? oldest.parentShowID
        merged.parentShowTitle = newest.parentShowTitle ?? oldest.parentShowTitle
        merged.parentShowPoster = newest.parentShowPoster ?? oldest.parentShowPoster
        merged.parentShowBanner = newest.parentShowBanner ?? oldest.parentShowBanner
        merged.seasonID = newest.seasonID ?? oldest.seasonID
        merged.seasonNumber = newest.seasonNumber ?? oldest.seasonNumber
        merged.seasonTitle = newest.seasonTitle ?? oldest.seasonTitle
        merged.seasonPoster = newest.seasonPoster ?? oldest.seasonPoster
        merged.episodeNumber = newest.episodeNumber ?? oldest.episodeNumber
        merged.title = newest.title.isEmpty ? oldest.title : newest.title
        merged.poster = newest.poster ?? oldest.poster
        merged.banner = newest.banner ?? oldest.banner
        merged.lastEngagementAtMillis = history?.lastEngagementAtMillis
        merged.playbackPositionMillis = history?.playbackPositionMillis
        merged.durationMillis = history?.durationMillis
        merged.isWatching = local.isWatching ?? remote.isWatching ?? newest.isWatching
        merged.clientUpdatedAtMillis = max(remote.clientUpdatedAtMillis, local.clientUpdatedAtMillis, now)
        return merged
    }
}

enum CloudSyncError: LocalizedError {
    case notConfigured, notSignedIn, kidsProfile, invalidURL
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Add your Supabase project URL and anon key first."
        case .notSignedIn: "Sign in to sync."
        case .kidsProfile: "Kids profiles can't sign in to cloud sync."
        case .invalidURL: "That Supabase URL isn't valid."
        case .server(let code, let message): "Supabase error \(code): \(message)"
        }
    }
}

/// Supabase-backed watchlist + history sync, ported from Android's
/// `CloudSyncManager`. Talks to the Auth and PostgREST REST APIs directly
/// (no SDK). The project URL and anon key are entered by the user, as on
/// Android. Each profile has its own signed-in session.
@MainActor
final class CloudSyncManager: ObservableObject {
    static let shared = CloudSyncManager()
    static let table = "user_media_state"
    static let conflictColumns = "user_id,provider,media_type,media_id"

    private static let urlKey = "cloud.supabase.url"
    private static let anonKeyKey = "cloud.supabase.anonKey"

    @Published private(set) var email: String?
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var lastMessage: String?

    private struct Session: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
        var userID: String
        var email: String?
    }

    private var session: Session? {
        didSet { email = session?.email }
    }

    private init() { reloadForActiveProfile() }

    // MARK: Auto-sync

    static let autoSyncDebounce: TimeInterval = 20

    private var autoSyncCancellable: AnyCancellable?
    private let pathMonitor = NWPathMonitor()
    private var isOnline = true
    private var pendingAutoSync = false
    private var ignoreChangesUntil = Date.distantPast
    private weak var autoSyncLibrary: LibraryStore?

    /// Syncs on launch and, debounced, after watchlist / watched / progress
    /// changes. Only runs when signed in; offline changes wait for the next
    /// change or for connectivity to return.
    func startAutoSync(library: LibraryStore) {
        guard autoSyncCancellable == nil else { return }
        autoSyncLibrary = library
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                let cameBack = online && !self.isOnline
                self.isOnline = online
                if cameBack && self.pendingAutoSync { self.autoSyncIfPossible() }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "cloud.sync.path"))
        autoSyncCancellable = Publishers.Merge3(
            library.$watchlist.map { _ in () },
            library.$progress.map { _ in () },
            library.$watchedEpisodes.map { _ in () }
        )
        .dropFirst(3)
        .filter { [weak self] in
            guard let self else { return false }
            return !self.isSyncing && Date() >= self.ignoreChangesUntil
        }
        .debounce(for: .seconds(Self.autoSyncDebounce), scheduler: DispatchQueue.main)
        .sink { [weak self] in self?.autoSyncIfPossible() }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.autoSyncIfPossible()
        }
    }

    private func autoSyncIfPossible() {
        guard let library = autoSyncLibrary, isSignedIn, isConfigured,
              !ProfileStore.shared.activeProfile.isKids else { return }
        guard isOnline else {
            pendingAutoSync = true
            return
        }
        pendingAutoSync = false
        Task { await syncNow(library: library) }
    }

    var projectURL: String { UserDefaults.standard.string(forKey: Self.urlKey) ?? "" }
    var anonKey: String { UserDefaults.standard.string(forKey: Self.anonKeyKey) ?? "" }
    var isConfigured: Bool { config != nil }
    var isSignedIn: Bool { session != nil }

    private var config: (url: URL, key: String)? {
        guard let url = Self.normalize(projectURL), !anonKey.isEmpty else { return nil }
        return (url, anonKey)
    }

    func saveConfig(url: String, anonKey: String) throws {
        let trimmedKey = anonKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized = Self.normalize(url) else { throw CloudSyncError.invalidURL }
        if normalized.absoluteString != projectURL || trimmedKey != self.anonKey { signOutLocally() }
        UserDefaults.standard.set(normalized.absoluteString, forKey: Self.urlKey)
        UserDefaults.standard.set(trimmedKey, forKey: Self.anonKeyKey)
        objectWillChange.send()
    }

    /// Call after switching profiles: each profile has its own cloud session.
    func reloadForActiveProfile() {
        session = Keychain.read(account: sessionAccount).flatMap { try? JSONDecoder().decode(Session.self, from: $0) }
        let stamp = UserDefaults.standard.double(forKey: lastSyncKey)
        lastSyncAt = stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
        lastMessage = nil
    }

    // MARK: Auth

    func signIn(email: String, password: String, library: LibraryStore) async throws {
        guard !ProfileStore.shared.activeProfile.isKids else { throw CloudSyncError.kidsProfile }
        let json = try await authRequest("token", query: [URLQueryItem(name: "grant_type", value: "password")],
                                         body: ["email": email, "password": password])
        try storeSession(from: json)
        await syncNow(library: library)
    }

    func signUp(email: String, password: String, library: LibraryStore) async throws {
        guard !ProfileStore.shared.activeProfile.isKids else { throw CloudSyncError.kidsProfile }
        let json = try await authRequest("signup", body: ["email": email, "password": password])
        if json["access_token"] != nil {
            try storeSession(from: json)
            await syncNow(library: library)
        } else {
            lastMessage = "Account created. Confirm the email, then sign in."
        }
    }

    func signOut() async {
        if let config, let session {
            var request = URLRequest(url: config.url.appending(path: "auth/v1/logout"))
            request.httpMethod = "POST"
            request.setValue(config.key, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
            _ = try? await URLSession.shared.data(for: request)
        }
        signOutLocally()
    }

    private func signOutLocally() {
        session = nil
        Keychain.delete(account: sessionAccount)
        UserDefaults.standard.removeObject(forKey: snapshotKey)
        UserDefaults.standard.removeObject(forKey: lastSyncKey)
        lastSyncAt = nil
    }

    private func authRequest(_ path: String, query: [URLQueryItem] = [], body: [String: String]) async throws -> [String: Any] {
        guard let config else { throw CloudSyncError.notConfigured }
        var components = URLComponents(url: config.url.appending(path: "auth/v1/\(path)"), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw CloudSyncError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(config.key, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = json["error_description"] as? String ?? json["msg"] as? String
                ?? json["message"] as? String ?? HTTPURLResponse.localizedString(forStatusCode: status)
            throw CloudSyncError.server(status, message)
        }
        return json
    }

    private func storeSession(from json: [String: Any]) throws {
        guard let access = json["access_token"] as? String,
              let refresh = json["refresh_token"] as? String,
              let user = json["user"] as? [String: Any],
              let userID = user["id"] as? String else {
            throw CloudSyncError.server(0, "Unexpected auth response")
        }
        let expiresIn = (json["expires_in"] as? Double) ?? (json["expires_in"] as? Int).map(Double.init) ?? 3600
        let value = Session(accessToken: access, refreshToken: refresh,
                            expiresAt: Date().addingTimeInterval(expiresIn - 60),
                            userID: userID, email: user["email"] as? String)
        if let data = try? JSONEncoder().encode(value) { Keychain.save(data, account: sessionAccount) }
        session = value
    }

    private func validSession(forceRefresh: Bool = false) async throws -> Session {
        guard let current = session else { throw CloudSyncError.notSignedIn }
        guard forceRefresh || current.expiresAt <= Date() else { return current }
        let json = try await authRequest("token", query: [URLQueryItem(name: "grant_type", value: "refresh_token")],
                                         body: ["refresh_token": current.refreshToken])
        try storeSession(from: json)
        guard let refreshed = session else { throw CloudSyncError.notSignedIn }
        return refreshed
    }

    // MARK: Sync

    func syncNow(library: LibraryStore) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer {
            isSyncing = false
            // Library edits applied from the cloud shouldn't schedule another sync.
            ignoreChangesUntil = Date().addingTimeInterval(1)
        }
        do {
            let summary = try await performSync(library: library)
            lastSyncAt = Date()
            UserDefaults.standard.set(lastSyncAt!.timeIntervalSince1970, forKey: lastSyncKey)
            lastMessage = summary
        } catch {
            lastMessage = error.localizedDescription
            if (error as? URLError)?.code == .notConnectedToInternet { pendingAutoSync = true }
        }
    }

    private func performSync(library: LibraryStore) async throws -> String {
        var current = try await validSession()
        let remoteRows: [CloudMediaState]
        do {
            remoteRows = try await fetchRemote(session: current)
        } catch CloudSyncError.server(401, _) {
            current = try await validSession(forceRefresh: true)
            remoteRows = try await fetchRemote(session: current)
        }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let snapshot = loadSnapshot()
        let local = localRows(library: library, userID: current.userID, snapshot: snapshot, now: now)
        let remote = Dictionary(remoteRows.map { ($0.key, $0) }, uniquingKeysWith: { lhs, rhs in
            lhs.clientUpdatedAtMillis >= rhs.clientUpdatedAtMillis ? lhs : rhs
        })

        var merged: [String: CloudMediaState] = [:]
        var uploads: [CloudMediaState] = []
        var applied = 0
        for key in Set(local.keys).union(remote.keys) {
            let localRow = local[key]
            let remoteRow = remote[key]
            var result: CloudMediaState
            if let localRow, let remoteRow {
                result = CloudMediaState.merge(remote: remoteRow, local: localRow, at: max(localRow.clientUpdatedAtMillis, remoteRow.clientUpdatedAtMillis))
            } else {
                result = localRow ?? remoteRow!
            }
            result.userID = current.userID
            if apply(result, over: localRow, library: library) { applied += 1 }
            if remoteRow.map({ $0.signature != result.signature || $0.title.isEmpty && !result.title.isEmpty }) ?? true {
                uploads.append(result)
            }
            merged[key] = result
        }
        try await upsert(uploads, session: current)
        saveSnapshot(merged)
        return "Synced \(merged.count) items · \(uploads.count) uploaded · \(applied) updated here"
    }

    private func fetchRemote(session: Session) async throws -> [CloudMediaState] {
        guard let config else { throw CloudSyncError.notConfigured }
        var rows: [CloudMediaState] = []
        let pageSize = 1000
        var offset = 0
        while true {
            var components = URLComponents(url: config.url.appending(path: "rest/v1/\(Self.table)"), resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "select", value: "*"),
                URLQueryItem(name: "user_id", value: "eq.\(session.userID)"),
                URLQueryItem(name: "order", value: "client_updated_at_millis.asc"),
                URLQueryItem(name: "limit", value: String(pageSize)),
                URLQueryItem(name: "offset", value: String(offset))
            ]
            let data = try await restRequest(components.url!, method: "GET", body: nil, session: session)
            let page = try JSONDecoder().decode([CloudMediaState].self, from: data)
            rows += page
            guard page.count == pageSize else { return rows }
            offset += pageSize
        }
    }

    private func upsert(_ rows: [CloudMediaState], session: Session) async throws {
        guard let config, !rows.isEmpty else { return }
        var components = URLComponents(url: config.url.appending(path: "rest/v1/\(Self.table)"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "on_conflict", value: Self.conflictColumns)]
        for start in stride(from: 0, to: rows.count, by: 250) {
            let chunk = Array(rows[start..<min(start + 250, rows.count)])
            _ = try await restRequest(components.url!, method: "POST", body: try JSONEncoder().encode(chunk),
                                      session: session, prefer: "resolution=merge-duplicates,return=minimal")
        }
    }

    private func restRequest(_ url: URL, method: String, body: Data?, session: Session, prefer: String? = nil) async throws -> Data {
        guard let config else { throw CloudSyncError.notConfigured }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(config.key, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let prefer { request.setValue(prefer, forHTTPHeaderField: "Prefer") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw CloudSyncError.server(status, json?["message"] as? String ?? String(decoding: data.prefix(200), as: UTF8.self))
        }
        return data
    }

    // MARK: Local state

    static func episodeMediaID(showID: String, season: Int, episode: Int) -> String {
        "\(showID)#S\(season)E\(episode)"
    }

    /// Builds rows from the library. A row keeps its last-synced timestamp unless
    /// its favorite/watched/progress state changed since the previous sync;
    /// rows that vanished locally (unfavorited, progress cleared) become "off" rows.
    private func localRows(library: LibraryStore, userID: String, snapshot: [String: CloudMediaState], now: Int64) -> [String: CloudMediaState] {
        var rows: [String: CloudMediaState] = [:]
        var showInfo: [String: MediaItem] = [:]
        for item in library.watchlist { showInfo[item.id] = item }
        for value in library.progress { showInfo[value.media.id] = value.media }

        func row(provider: String, type: String, id: String) -> CloudMediaState {
            let key = [provider, type, id].joined(separator: "|")
            return rows[key] ?? CloudMediaState(userID: userID, provider: provider, mediaType: type, mediaID: id)
        }
        func put(_ value: CloudMediaState) { rows[value.key] = value }

        for item in library.watchlist {
            var value = row(provider: item.providerID, type: item.kind.rawValue, id: item.id)
            value.title = item.title
            value.poster = item.posterURL?.absoluteString
            value.banner = item.backdropURL?.absoluteString
            value.isFavorite = true
            value.favoritedAtMillis = snapshot[value.key]?.favoritedAtMillis ?? now
            put(value)
        }
        for progress in library.progress {
            let updated = Int64(progress.updatedAt.timeIntervalSince1970 * 1000)
            var value: CloudMediaState
            if let episode = progress.episode {
                value = row(provider: progress.media.providerID, type: "episode",
                            id: Self.episodeMediaID(showID: progress.media.id, season: episode.seasonNumber, episode: episode.number))
                fillEpisode(&value, show: progress.media, season: episode.seasonNumber, number: episode.number)
                value.title = episode.title ?? progress.media.title
            } else {
                value = row(provider: progress.media.providerID, type: progress.media.kind.rawValue, id: progress.media.id)
                value.title = progress.media.title
                value.poster = progress.media.posterURL?.absoluteString
                value.banner = progress.media.backdropURL?.absoluteString
            }
            guard progress.duration > 0 else { continue }
            value.lastEngagementAtMillis = updated
            value.playbackPositionMillis = Int64(progress.position * 1000)
            value.durationMillis = Int64(progress.duration * 1000)
            value.isWatching = true
            put(value)
        }
        for watched in library.watchedEpisodes {
            var value = row(provider: watched.providerID, type: "episode",
                            id: Self.episodeMediaID(showID: watched.showID, season: watched.seasonNumber, episode: watched.episodeNumber))
            if let show = showInfo[watched.showID] {
                fillEpisode(&value, show: show, season: watched.seasonNumber, number: watched.episodeNumber)
            } else {
                value.parentShowID = watched.showID
                value.seasonNumber = watched.seasonNumber
                value.episodeNumber = watched.episodeNumber
            }
            value.isWatched = true
            value.watchedAtMillis = snapshot[value.key]?.watchedAtMillis ?? now
            put(value)
        }
        for (key, previous) in snapshot where rows[key] == nil {
            var off = previous
            off.isFavorite = false
            off.favoritedAtMillis = nil
            off.isWatched = false
            off.watchedAtMillis = nil
            off.playbackPositionMillis = nil
            off.durationMillis = nil
            off.lastEngagementAtMillis = nil
            rows[key] = off
        }
        for (key, value) in rows {
            var stamped = value
            if let previous = snapshot[key], previous.signature == value.signature {
                stamped.clientUpdatedAtMillis = previous.clientUpdatedAtMillis
            } else {
                stamped.clientUpdatedAtMillis = now
            }
            rows[key] = stamped
        }
        return rows
    }

    private func fillEpisode(_ value: inout CloudMediaState, show: MediaItem, season: Int, number: Int) {
        value.parentShowID = show.id
        value.parentShowTitle = show.title
        value.parentShowPoster = show.posterURL?.absoluteString
        value.parentShowBanner = show.backdropURL?.absoluteString
        value.seasonNumber = season
        value.episodeNumber = number
    }

    /// Writes a merged row into the existing LibraryStore. Returns true when
    /// something local changed.
    private func apply(_ state: CloudMediaState, over local: CloudMediaState?, library: LibraryStore) -> Bool {
        var changed = false
        if state.mediaType == "episode" {
            guard let showID = state.parentShowID, let season = state.seasonNumber, let number = state.episodeNumber else { return false }
            let show = MediaItem(
                id: showID, providerID: state.provider, kind: .series,
                title: state.parentShowTitle ?? state.title, originalTitle: nil, overview: nil,
                releaseDate: nil, rating: nil, tmdbID: nil,
                posterURL: state.parentShowPoster.flatMap(URL.init(string:)),
                backdropURL: state.parentShowBanner.flatMap(URL.init(string:)), genres: []
            )
            let episode = MediaEpisode(
                id: state.mediaID, providerID: state.provider, showID: showID,
                seasonNumber: season, number: number, title: state.title.isEmpty ? nil : state.title,
                overview: nil, posterURL: nil
            )
            let request = PlaybackRequest(media: show, episode: episode)
            if state.isWatched != (local?.isWatched ?? false) {
                state.isWatched ? library.markWatched(request: request) : library.markUnwatched(request: request)
                changed = true
            }
            if applyProgress(state, over: local, request: request, library: library) { changed = true }
            return changed
        }
        let kind: MediaKind = state.mediaType == MediaKind.series.rawValue ? .series : .movie
        let item = library.watchlist.first { $0.id == state.mediaID && $0.providerID == state.provider }
            ?? MediaItem(
                id: state.mediaID, providerID: state.provider, kind: kind, title: state.title,
                originalTitle: nil, overview: nil, releaseDate: nil, rating: nil, tmdbID: nil,
                posterURL: state.poster.flatMap(URL.init(string:)),
                backdropURL: state.banner.flatMap(URL.init(string:)), genres: []
            )
        if state.isFavorite != library.isInWatchlist(item) {
            library.toggleWatchlist(item)
            changed = true
        }
        if kind == .movie, applyProgress(state, over: local, request: PlaybackRequest(media: item, episode: nil), library: library) {
            changed = true
        }
        return changed
    }

    private func applyProgress(_ state: CloudMediaState, over local: CloudMediaState?, request: PlaybackRequest, library: LibraryStore) -> Bool {
        guard !state.isWatched,
              let engaged = state.lastEngagementAtMillis,
              engaged > (local?.lastEngagementAtMillis ?? 0) + 1000,
              let position = state.playbackPositionMillis, let duration = state.durationMillis,
              position > 0, duration > 0 else { return false }
        library.updateProgress(request: request, position: Double(position) / 1000, duration: Double(duration) / 1000)
        return true
    }

    // MARK: Storage

    private var profileID: String { ProfileStore.shared.activeProfileID }
    private var sessionAccount: String { "supabase-session-\(profileID)" }
    private var snapshotKey: String { "cloud.snapshot.\(profileID)" }
    private var lastSyncKey: String { "cloud.lastSync.\(profileID)" }

    private func loadSnapshot() -> [String: CloudMediaState] {
        guard let data = UserDefaults.standard.data(forKey: snapshotKey),
              let rows = try? JSONDecoder().decode([CloudMediaState].self, from: data) else { return [:] }
        return Dictionary(rows.map { ($0.key, $0) }, uniquingKeysWith: { lhs, _ in lhs })
    }

    private func saveSnapshot(_ rows: [String: CloudMediaState]) {
        if let data = try? JSONEncoder().encode(Array(rows.values)) {
            UserDefaults.standard.set(data, forKey: snapshotKey)
        }
    }

    private static func normalize(_ raw: String) -> URL? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if !value.contains("://") { value = "https://\(value)" }
        while value.hasSuffix("/") { value.removeLast() }
        guard let url = URL(string: value), url.scheme == "https" || url.scheme == "http", url.host != nil else { return nil }
        return url
    }

    private enum Keychain {
        static let service = "\(Bundle.main.bundleIdentifier ?? "BetterStreamflix").cloud"

        static func read(account: String) -> Data? {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var result: AnyObject?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
            return result as? Data
        }

        static func save(_ data: Data, account: String) {
            delete(account: account)
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
                kSecValueData as String: data
            ]
            SecItemAdd(query as CFDictionary, nil)
        }

        static func delete(account: String) {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            SecItemDelete(query as CFDictionary)
        }
    }
}
