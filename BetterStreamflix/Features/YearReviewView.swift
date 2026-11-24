import SwiftUI

struct YearReviewView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var year = Calendar.current.component(.year, from: Date())

    private var stats: YearReviewStats {
        YearReviewStats.compute(year: year, events: library.watchEvents, inProgress: library.progress)
    }

    private var years: [Int] {
        let current = Calendar.current.component(.year, from: Date())
        let logged = library.watchEvents.map { Calendar.current.component(.year, from: $0.finishedAt) }
        return Array(Set(logged + [current])).sorted(by: >)
    }

    var body: some View {
        let stats = stats
        List {
            if years.count > 1 {
                Picker("Year", selection: $year) {
                    ForEach(years, id: \.self) { Text(String($0)).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("\(String(year)) · \(ProfileStore.shared.activeProfile.displayName)") {
                LabeledContent("Hours watched", value: stats.totalHours.formatted(.number.precision(.fractionLength(0...1))))
                LabeledContent("Movies", value: "\(stats.movieCount)")
                LabeledContent("Episodes", value: "\(stats.episodeCount)")
            }
            if !stats.topSeries.isEmpty {
                Section("Top series") {
                    ForEach(Array(stats.topSeries.enumerated()), id: \.element.id) { index, series in
                        HStack {
                            Text("\(index + 1).").foregroundStyle(.secondary).monospacedDigit()
                            Text(series.title.isEmpty ? "Unknown" : series.title)
                            Spacer()
                            Text("\(series.episodeCount) ep · \(series.estimatedMinutes / 60) h")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let binge = stats.longestBinge {
                Section("Longest binge") {
                    Text(binge.title).font(.body.weight(.semibold))
                    Text("\(binge.episodeCount) episodes · about \(binge.estimatedMinutes) min · \(binge.start.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !stats.hasActivity {
                Text("Nothing finished in \(String(year)) yet. Finished movies and episodes are counted from now on.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Year in Review")
    }
}
