import Foundation

/// Lightweight provider smoke test: registry sanity checks plus timed probes
/// whose outcomes feed `ProviderHealth`, so providers that fail repeatedly are
/// skipped by playback lookup and listed in the outage notice.
enum ProviderSmoke {
    static let homeTimeout: TimeInterval = 25
    static let serversTimeout: TimeInterval = 20
    /// German lookups fan out to slower sites (SerienStream, Moflix).
    static let serversTimeoutGerman: TimeInterval = 35
    static let catalogTimeout: TimeInterval = 25
    static let searchTimeout: TimeInterval = 20
    static let detailTimeout: TimeInterval = 25

    /// Providers that matter most; reported when the registry lacks them.
    static let smokeTargets: [PlaybackSourcePreferenceID] = [
        .serienstream, .streamingCommunity, .guardaflix, .guardaserie, .hdfilme, .frembed,
        .aniworld, .cine24h, .sololatino, .megakino, .filmpalast, .kinoger, .hiAnime
    ]

    static let sampleRequest = PlaybackRequest(
        media: MediaItem(
            id: "tmdb:movie:27205",
            providerID: "tmdb",
            kind: .movie,
            title: "Inception",
            releaseDate: "2010-07-15",
            imdbID: "tt1375666",
            tmdbID: 27205
        ),
        episode: nil
    )

    static let seriesSampleRequest = PlaybackRequest(
        media: MediaItem(
            id: "tmdb:tv:119051",
            providerID: "tmdb",
            kind: .series,
            title: "Wednesday",
            releaseDate: "2022-11-23",
            imdbID: "tt13443470",
            tmdbID: 119051
        ),
        episode: MediaEpisode(
            id: "tmdb:tv:119051-s1e1",
            providerID: "tmdb",
            showID: "tmdb:tv:119051",
            seasonNumber: 1,
            number: 1,
            title: "Wednesday's Child Is Full of Woe",
            overview: nil,
            posterURL: nil
        )
    )

    struct RegistryReport: Sendable {
        let totalProviders: Int
        let duplicateIDs: [String]
        let missingSmokeTargets: [String]
        let quarantinedCount: Int

        var ok: Bool { duplicateIDs.isEmpty }
    }

    struct Result: Identifiable, Sendable {
        let id: String
        let ok: Bool
        let itemCount: Int
        let duration: TimeInterval
        let message: String?
    }

    struct TimeoutError: LocalizedError {
        let label: String
        let seconds: TimeInterval
        var errorDescription: String? { "\(label) timed out after \(Int(seconds))s" }
    }

    static func validateRegistry(
        _ providers: [any PlaybackProvider],
        targets: [PlaybackSourcePreferenceID] = smokeTargets
    ) -> RegistryReport {
        let ids = providers.map(\.id)
        let duplicates = Dictionary(grouping: ids, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        let missing = targets.filter { target in !ids.contains { target.matches(providerID: $0) } }
        return RegistryReport(
            totalProviders: ids.count,
            duplicateIDs: duplicates,
            missingSmokeTargets: missing.map(\.rawValue),
            quarantinedCount: ProviderHealth.quarantinedIDs.count
        )
    }

    static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        label: String,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw TimeoutError(label: label, seconds: seconds)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }

    /// Probes the registered playback providers with a sample title lookup and
    /// the live providers with a channel-list fetch.
    static func run(registry: ProviderRegistry, includeLive: Bool = true) async -> (RegistryReport, [Result]) {
        let providers = await registry.playbackProviders()
        let report = validateRegistry(providers)
        let results = await run(playback: providers, live: includeLive ? LiveTVProviders.all() : [])
        return (report, results)
    }

    static func run(
        playback: [any PlaybackProvider],
        live: [any LiveTVProvider] = [],
        concurrency: Int = 6,
        health: ProviderHealth = .shared
    ) async -> [Result] {
        typealias Job = (id: String, timeout: TimeInterval, operation: @Sendable () async throws -> Int)
        let movieContext = PlaybackLookupContext(request: sampleRequest)
        let seriesContext = PlaybackLookupContext(request: seriesSampleRequest)
        var jobs: [Job] = playback.map { provider in
            let german = PlaybackSourcePreferenceID.allCases
                .first { $0.matches(providerID: provider.id) }?.languageGroup == .german
            // Series-only providers must be probed with a series — a movie sample
            // structurally yields zero and was mistaken for breakage.
            let seriesOnly = provider is SerienStreamPlaybackProvider
                || provider is AniWorldPlaybackProvider
                || (provider as? CfGenericPlaybackProvider)?.supportsMovies == false
            let context = seriesOnly ? seriesContext : movieContext
            return (provider.id, german ? serversTimeoutGerman : serversTimeout, {
                try await provider.candidates(for: context).count
            })
        }
        jobs += live.map { provider in (provider.id, catalogTimeout, { try await provider.channels().count }) }

        return await withTaskGroup(of: Result.self) { group in
            var next = 0
            while next < min(max(concurrency, 1), jobs.count) {
                let job = jobs[next]
                next += 1
                group.addTask { await probe(job.id, timeout: job.timeout, health: health, job.operation) }
            }
            var results: [Result] = []
            while let result = await group.next() {
                results.append(result)
                if next < jobs.count {
                    let job = jobs[next]
                    next += 1
                    group.addTask { await probe(job.id, timeout: job.timeout, health: health, job.operation) }
                }
            }
            return results.sorted { $0.id < $1.id }
        }
    }

    private static func probe(
        _ id: String,
        timeout: TimeInterval,
        health: ProviderHealth,
        _ operation: @escaping @Sendable () async throws -> Int
    ) async -> Result {
        let started = Date()
        do {
            let count = try await withTimeout(timeout, label: id, operation)
            await health.recordSuccess(id)
            return Result(id: id, ok: true, itemCount: count, duration: Date().timeIntervalSince(started), message: nil)
        } catch is CancellationError {
            return Result(id: id, ok: false, itemCount: 0, duration: Date().timeIntervalSince(started), message: "Cancelled")
        } catch {
            await health.recordFailure(id)
            return Result(
                id: id, ok: false, itemCount: 0,
                duration: Date().timeIntervalSince(started),
                message: error.localizedDescription
            )
        }
    }
}
