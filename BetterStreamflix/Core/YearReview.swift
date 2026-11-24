import Foundation

/// A finished movie or episode, recorded when playback completes.
struct WatchEvent: Codable, Hashable, Sendable {
    let contentID: String
    let showKey: String?
    let title: String
    let showTitle: String?
    let posterURL: URL?
    let runtimeMinutes: Int?
    let finishedAt: Date

    init(request: PlaybackRequest, finishedAt: Date = Date()) {
        contentID = request.contentID
        showKey = request.episode == nil ? nil : "\(request.media.providerID):\(request.media.id)"
        title = request.episode?.title ?? request.media.title
        showTitle = request.episode == nil ? nil : request.media.title
        posterURL = request.media.posterURL
        runtimeMinutes = request.episode == nil ? request.media.runtimeMinutes : nil
        self.finishedAt = finishedAt
    }
}

/// Port of Android's YearReviewCalculator: estimated hours, counts, top series
/// and the longest binge (episodes of one show finished less than 3 h apart).
struct YearReviewStats: Sendable {
    struct TopSeries: Identifiable, Sendable {
        var id: String { showKey }
        let showKey: String
        let title: String
        let posterURL: URL?
        let episodeCount: Int
        let estimatedMinutes: Int
    }

    struct LongestBinge: Sendable {
        let title: String
        let episodeCount: Int
        let estimatedMinutes: Int
        let start: Date
        let end: Date
    }

    static let defaultMovieMinutes = 100
    static let defaultEpisodeMinutes = 45
    static let bingeGap: TimeInterval = 3 * 60 * 60
    static let topSeriesCount = 3

    let year: Int
    let totalHours: Double
    let movieCount: Int
    let episodeCount: Int
    let topSeries: [TopSeries]
    let longestBinge: LongestBinge?

    var hasActivity: Bool { movieCount > 0 || episodeCount > 0 || totalHours > 0 }

    static func compute(year: Int, events: [WatchEvent], inProgress: [WatchProgress], calendar: Calendar = .current) -> YearReviewStats {
        let inYear = { (date: Date) in calendar.component(.year, from: date) == year }
        let finished = events.filter { inYear($0.finishedAt) }
        let movies = finished.filter { $0.showKey == nil }
        let episodes = finished.filter { $0.showKey != nil }
        var minutes = Double(movies.reduce(0) { $0 + minutesOf($1, fallback: defaultMovieMinutes) })
        minutes += Double(episodes.reduce(0) { $0 + minutesOf($1, fallback: defaultEpisodeMinutes) })
        minutes += inProgress.filter { inYear($0.updatedAt) && $0.position > 0 }.reduce(0) { $0 + $1.position / 60 }
        return YearReviewStats(
            year: year,
            totalHours: (minutes / 60 * 10).rounded() / 10,
            movieCount: movies.count,
            episodeCount: episodes.count,
            topSeries: rankTopSeries(episodes),
            longestBinge: findLongestBinge(episodes)
        )
    }

    private static func minutesOf(_ event: WatchEvent, fallback: Int) -> Int {
        event.runtimeMinutes.flatMap { $0 > 0 ? $0 : nil } ?? fallback
    }

    static func rankTopSeries(_ episodes: [WatchEvent]) -> [TopSeries] {
        var order: [String] = []
        var acc: [String: (title: String, poster: URL?, count: Int, minutes: Int)] = [:]
        for episode in episodes {
            guard let key = episode.showKey else { continue }
            if acc[key] == nil {
                order.append(key)
                acc[key] = (episode.showTitle ?? "", episode.posterURL, 0, 0)
            }
            acc[key]!.count += 1
            acc[key]!.minutes += minutesOf(episode, fallback: defaultEpisodeMinutes)
            if acc[key]!.title.isEmpty, let title = episode.showTitle { acc[key]!.title = title }
            if acc[key]!.poster == nil { acc[key]!.poster = episode.posterURL }
        }
        return order
            .compactMap { key in acc[key].map { TopSeries(showKey: key, title: $0.title, posterURL: $0.poster, episodeCount: $0.count, estimatedMinutes: $0.minutes) } }
            .sorted {
                if $0.episodeCount != $1.episodeCount { return $0.episodeCount > $1.episodeCount }
                if $0.estimatedMinutes != $1.estimatedMinutes { return $0.estimatedMinutes > $1.estimatedMinutes }
                return $0.title.lowercased() < $1.title.lowercased()
            }
            .prefix(topSeriesCount)
            .map { $0 }
    }

    static func findLongestBinge(_ episodes: [WatchEvent]) -> LongestBinge? {
        var best: LongestBinge?
        for (key, list) in Dictionary(grouping: episodes, by: { $0.showKey ?? "" }) where !key.isEmpty {
            let sorted = list.sorted { $0.finishedAt < $1.finishedAt }
            var sessionStart = 0
            func consider(_ range: Range<Int>) {
                guard range.count >= 2 else { return }
                let slice = sorted[range]
                let candidate = LongestBinge(
                    title: slice.first?.showTitle ?? key,
                    episodeCount: range.count,
                    estimatedMinutes: slice.reduce(0) { $0 + minutesOf($1, fallback: defaultEpisodeMinutes) },
                    start: slice.first!.finishedAt,
                    end: slice.last!.finishedAt
                )
                best = better(best, candidate)
            }
            for index in sorted.indices.dropFirst()
            where sorted[index].finishedAt.timeIntervalSince(sorted[index - 1].finishedAt) > bingeGap {
                consider(sessionStart..<index)
                sessionStart = index
            }
            consider(sessionStart..<sorted.count)
        }
        return best
    }

    private static func better(_ current: LongestBinge?, _ candidate: LongestBinge) -> LongestBinge {
        guard let current else { return candidate }
        if candidate.episodeCount != current.episodeCount { return candidate.episodeCount > current.episodeCount ? candidate : current }
        if candidate.estimatedMinutes != current.estimatedMinutes { return candidate.estimatedMinutes > current.estimatedMinutes ? candidate : current }
        return candidate.end.timeIntervalSince(candidate.start) >= current.end.timeIntervalSince(current.start) ? candidate : current
    }
}
