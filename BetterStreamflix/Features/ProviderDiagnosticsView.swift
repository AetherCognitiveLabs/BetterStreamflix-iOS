import SwiftUI

/// Runs `ProviderSmoke` against every registered playback and live provider and
/// shows the per-provider result plus the current ProviderHealth state.
struct ProviderDiagnosticsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var report: ProviderSmoke.RegistryReport?
    @State private var results: [ProviderSmoke.Result] = []
    @State private var skipped: Set<String> = []
    @State private var isRunning = false
    @State private var includeLive = true
    @State private var startedAt: Date?

    var body: some View {
        List {
            Section {
                Toggle("Include Live TV", isOn: $includeLive)
                Button {
                    Task { await run() }
                } label: {
                    HStack {
                        Text(isRunning ? "Running…" : "Run smoke test")
                        if isRunning { Spacer(); ProgressView() }
                    }
                }
                .disabled(isRunning)
            } footer: {
                Text("Searches each provider for a sample title and loads each live channel list. Results feed provider health, so failing providers are skipped during playback.")
            }

            if let report {
                Section("Registry") {
                    LabeledContent("Providers", value: "\(report.totalProviders)")
                    LabeledContent("Passed", value: "\(results.filter(\.ok).count) / \(results.count)")
                    if !report.duplicateIDs.isEmpty {
                        LabeledContent("Duplicate IDs", value: report.duplicateIDs.joined(separator: ", "))
                    }
                    if !report.missingSmokeTargets.isEmpty {
                        LabeledContent("Missing key providers", value: report.missingSmokeTargets.joined(separator: ", "))
                    }
                }
            }

            if !results.isEmpty {
                Section("Results") {
                    ForEach(results.sorted { ($0.ok ? 1 : 0, $0.id) < ($1.ok ? 1 : 0, $1.id) }) { result in
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(result.ok ? .green : .red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.id).font(.body.monospaced())
                                if let message = result.message {
                                    Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(result.itemCount)").monospacedDigit()
                                Text(String(format: "%.1fs", result.duration)).font(.caption2).foregroundStyle(.secondary)
                                if skipped.contains(result.id) {
                                    Text("skipped").font(.caption2).foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Provider Diagnostics")
    }

    private func run() async {
        isRunning = true
        defer { isRunning = false }
        let (report, results) = await ProviderSmoke.run(registry: environment.registry, includeLive: includeLive)
        self.report = report
        self.results = results
        skipped = Set(await ProviderHealth.shared.outageProviderIDs())
    }
}
