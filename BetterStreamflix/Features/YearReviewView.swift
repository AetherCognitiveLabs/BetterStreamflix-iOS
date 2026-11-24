import SwiftUI

/// Year in Review showcase: headline hours, counts, the top series as a poster
/// podium and the longest binge.
struct YearReviewView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var environment: AppEnvironment
    @State private var year = Calendar.current.component(.year, from: Date())

    private var stats: YearReviewStats {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-yearReviewDemo") { return .demo(year: year) }
        #endif
        return YearReviewStats.compute(year: year, events: library.watchEvents, inProgress: library.progress)
    }

    private var years: [Int] {
        let current = Calendar.current.component(.year, from: Date())
        let logged = library.watchEvents.map { Calendar.current.component(.year, from: $0.finishedAt) }
        return Array(Set(logged + [current])).sorted(by: >)
    }

    var body: some View {
        let stats = stats
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                hero(stats)
                if stats.hasActivity {
                    countCards(stats)
                    if !stats.topSeries.isEmpty { podium(stats.topSeries) }
                    if let binge = stats.longestBinge { bingeCard(binge) }
                } else {
                    emptyState
                }
            }
            .padding(.bottom, 120)
        }
        .scrollIndicators(.hidden)
        .ignoresSafeArea(edges: .top)
        .background { AppScreenBackground() }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    private func hero(_ stats: YearReviewStats) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("YOUR \(String(year)) · \(ProfileStore.shared.activeProfile.displayName.uppercased())")
                    .font(.caption.weight(.bold))
                    .tracking(1.4)
                    .foregroundStyle(environment.theme.accentBright)
                Text("Year in Review")
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(.white)
            }
            if years.count > 1 { yearChips }
            if stats.hasActivity {
            VStack(alignment: .leading, spacing: 0) {
                Text(stats.totalHours.formatted(.number.precision(.fractionLength(0...1))))
                    .font(.system(size: 96, weight: .heavy, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(colors: [.white, environment.theme.accentBright], startPoint: .top, endPoint: .bottom)
                    )
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                Text("hours watched")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.75))
            }
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.screenHorizontal)
        .padding(.top, 110)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .top) {
            ZStack {
                if let poster = stats.topSeries.first?.posterURL {
                    AsyncImage(url: poster) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                        .frame(height: 440)
                        .frame(maxWidth: .infinity)
                        .blur(radius: 50)
                        .opacity(0.5)
                }
                RadialGradient(colors: [environment.theme.accent.opacity(0.45), .clear], center: .topTrailing, startRadius: 10, endRadius: 380)
            }
            .frame(height: 440)
            .clipped()
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.45), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
        }
    }

    private var yearChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(years, id: \.self) { value in
                    let selected = value == year
                    Button {
                        withAnimation(DesignTokens.Motion.soft) { year = value }
                    } label: {
                        Text(String(value))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(selected ? Color(hex: 0x11141C) : .white.opacity(0.85))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(selected ? AnyShapeStyle(environment.theme.accentBright) : AnyShapeStyle(AppTheme.surface)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func countCards(_ stats: YearReviewStats) -> some View {
        HStack(spacing: 12) {
            countCard(value: stats.movieCount, label: stats.movieCount == 1 ? "movie" : "movies", systemImage: "film.fill")
            countCard(value: stats.episodeCount, label: stats.episodeCount == 1 ? "episode" : "episodes", systemImage: "tv.fill")
        }
        .padding(.horizontal, DesignTokens.Spacing.screenHorizontal)
    }

    private func countCard(value: Int, label: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: systemImage)
                .font(.headline)
                .foregroundStyle(environment.theme.accentBright)
                .frame(width: 36, height: 36)
                .background(Circle().fill(environment.theme.accent.opacity(0.18)))
            Text("\(value)")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
            Text(label)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface(cornerRadius: DesignTokens.Radius.card)
    }

    private func podium(_ series: [YearReviewStats.TopSeries]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Top Series")
                .font(DesignTokens.Typography.shelfTitle)
                .foregroundStyle(.white)
                .padding(.horizontal, DesignTokens.Spacing.screenHorizontal)
            HStack(alignment: .bottom, spacing: 12) {
                ForEach(Array(series.enumerated()), id: \.element.id) { index, item in
                    podiumPoster(item, rank: index + 1)
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.screenHorizontal)
        }
    }

    private func podiumPoster(_ item: YearReviewStats.TopSeries, rank: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay {
                    AsyncImage(url: item.posterURL) { $0.resizable().scaledToFill() } placeholder: {
                        ZStack {
                            AppTheme.surface
                            Image(systemName: "tv").font(.title2).foregroundStyle(.white.opacity(0.3))
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.poster, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    Text("\(rank)")
                        .font(.system(size: rank == 1 ? 64 : 52, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.7), radius: 8, y: 2)
                        .offset(x: -6, y: 18)
                }
                .overlay {
                    if rank == 1 {
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.poster, style: .continuous)
                            .stroke(environment.theme.accentBright, lineWidth: 2)
                    }
                }
                .shadow(color: rank == 1 ? environment.theme.accent.opacity(0.5) : .black.opacity(0.4), radius: 14, y: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title.isEmpty ? "Unknown" : item.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(item.episodeCount) ep · \(item.estimatedMinutes / 60) h")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.58))
            }
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity)
        .scaleEffect(rank == 1 ? 1 : 0.92, anchor: .bottom)
    }

    private func bingeCard(_ binge: YearReviewStats.LongestBinge) -> some View {
        HStack(spacing: 16) {
            Image(systemName: "flame.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [Color(hex: 0xFFC14D), Color(hex: 0xE5383B)], startPoint: .top, endPoint: .bottom))
                .frame(width: 60, height: 60)
                .background(Circle().fill(Color(hex: 0xE5383B).opacity(0.16)))
            VStack(alignment: .leading, spacing: 4) {
                Text("LONGEST BINGE")
                    .font(.caption2.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.55))
                Text(binge.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(binge.episodeCount) episodes in a row · \(binge.estimatedMinutes / 60) h \(binge.estimatedMinutes % 60) min")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                Text(binge.start.formatted(date: .long, time: .omitted))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .appSurface(cornerRadius: DesignTokens.Radius.card)
        .padding(.horizontal, DesignTokens.Spacing.screenHorizontal)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles.tv.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(environment.theme.accentBright)
                .frame(width: 96, height: 96)
                .background(Circle().fill(environment.theme.accent.opacity(0.16)))
                .shadow(color: environment.theme.accent.opacity(0.5), radius: 24)
            Text("Your \(String(year)) starts here")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
            Text("Finish movies and episodes and they'll show up here: hours, top series and your longest binge.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 32)
    }
}

#if DEBUG
private extension YearReviewStats {
    static func demo(year: Int) -> YearReviewStats {
        let poster = { (path: String) in URL(string: "https://image.tmdb.org/t/p/w342\(path)") }
        return YearReviewStats(
            year: year,
            totalHours: 214.5,
            movieCount: 38,
            episodeCount: 196,
            topSeries: [
                .init(showKey: "a", title: "Breaking Bad", posterURL: poster("/ggFHVNu6YYI5L9pCfOacjizRGt.jpg"), episodeCount: 62, estimatedMinutes: 2790),
                .init(showKey: "b", title: "Stranger Things", posterURL: poster("/49WJfeN0moxb9IPfGn8AIqMGskD.jpg"), episodeCount: 34, estimatedMinutes: 1530),
                .init(showKey: "c", title: "The Last of Us", posterURL: poster("/uKvVjHNqB5VmOrdxqAt2F7J78ED.jpg"), episodeCount: 16, estimatedMinutes: 720),
            ],
            longestBinge: .init(title: "Breaking Bad", episodeCount: 9, estimatedMinutes: 405, start: Date(timeIntervalSince1970: 1_767_000_000), end: Date(timeIntervalSince1970: 1_767_024_300))
        )
    }
}
#endif
