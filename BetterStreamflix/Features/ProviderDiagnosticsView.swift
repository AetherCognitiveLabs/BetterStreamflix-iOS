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

    private var passed: Int { results.filter(\.ok).count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Diagnostics")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Searches each provider for a sample title and loads every live channel list. Failing providers are skipped during playback.")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.top, 8)
                summaryCard
                if !results.isEmpty { resultsSection }
            }
            .padding(.horizontal, DesignTokens.Spacing.screenHorizontal)
            .padding(.bottom, 120)
        }
        .scrollIndicators(.hidden)
        .background { AppScreenBackground() }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        #if DEBUG
        .task {
            if ProcessInfo.processInfo.arguments.contains("-runDiagnostics"), results.isEmpty { await run() }
        }
        #endif
    }

    private var summaryCard: some View {
        VStack(spacing: 18) {
            HStack(spacing: 20) {
                ZStack {
                    Circle().stroke(.white.opacity(0.08), lineWidth: 10)
                    Circle()
                        .trim(from: 0, to: results.isEmpty ? 0 : CGFloat(passed) / CGFloat(results.count))
                        .stroke(
                            passed == results.count ? Color(hex: 0x4CC9A6) : environment.theme.accentBright,
                            style: StrokeStyle(lineWidth: 10, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .animation(DesignTokens.Motion.soft, value: passed)
                    VStack(spacing: 0) {
                        if isRunning {
                            ProgressView().tint(.white)
                        } else {
                            Text(results.isEmpty ? "–" : "\(passed)")
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                            Text(results.isEmpty ? "not run" : "of \(results.count)")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                }
                .frame(width: 104, height: 104)
                VStack(alignment: .leading, spacing: 10) {
                    stat("Providers", value: report.map { "\($0.totalProviders)" } ?? "–")
                    stat("Failing", value: results.isEmpty ? "–" : "\(results.count - passed)", alert: results.count - passed > 0)
                    stat("Skipped by health", value: results.isEmpty ? "–" : "\(skipped.count)", alert: !skipped.isEmpty)
                }
                Spacer(minLength: 0)
            }
            if let report, !report.duplicateIDs.isEmpty || !report.missingSmokeTargets.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if !report.duplicateIDs.isEmpty {
                        Label("Duplicate IDs: \(report.duplicateIDs.joined(separator: ", "))", systemImage: "exclamationmark.triangle.fill")
                    }
                    if !report.missingSmokeTargets.isEmpty {
                        Label("Not registered: \(report.missingSmokeTargets.joined(separator: ", "))", systemImage: "questionmark.circle")
                    }
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().overlay(AppTheme.border)
            Toggle(isOn: $includeLive) {
                Label("Include Live TV", systemImage: "dot.radiowaves.left.and.right")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
            }
            .tint(environment.theme.accent)
            Button {
                Task { await run() }
            } label: {
                Label(isRunning ? "Running…" : (results.isEmpty ? "Run Smoke Test" : "Run Again"), systemImage: "stethoscope")
            }
            .buttonStyle(AppPrimaryButtonStyle(glow: environment.theme.accent, minHeight: 48, verticalPadding: 12))
            .disabled(isRunning)
        }
        .padding(18)
        .appSurface(cornerRadius: DesignTokens.Radius.card)
    }

    private func stat(_ label: String, value: String, alert: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(value)
                .font(.headline.weight(.bold).monospacedDigit())
                .foregroundStyle(alert ? Color(hex: 0xFF6B6B) : .white)
                .frame(minWidth: 28, alignment: .leading)
            Text(label).font(.caption).foregroundStyle(.white.opacity(0.6))
        }
    }

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Results").font(DesignTokens.Typography.shelfTitle).foregroundStyle(.white)
            LazyVStack(spacing: 0) {
                let sorted = results.sorted { ($0.ok ? 1 : 0, $0.id) < ($1.ok ? 1 : 0, $1.id) }
                ForEach(Array(sorted.enumerated()), id: \.element.id) { index, result in
                    if index > 0 { Divider().overlay(AppTheme.border).padding(.leading, 44) }
                    resultRow(result)
                }
            }
            .appSurface(cornerRadius: DesignTokens.Radius.card)
        }
    }

    private func resultRow(_ result: ProviderSmoke.Result) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: result.ok ? "checkmark" : "xmark")
                .font(.caption.weight(.heavy))
                .foregroundStyle(result.ok ? Color(hex: 0x0E3B2F) : .white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(result.ok ? Color(hex: 0x4CC9A6) : Color(hex: 0xE5383B)))
            VStack(alignment: .leading, spacing: 2) {
                Text(result.id).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                if let message = result.message {
                    Text(message).font(.caption).foregroundStyle(.white.opacity(0.55)).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(result.itemCount) items").font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(.white.opacity(0.85))
                HStack(spacing: 4) {
                    if skipped.contains(result.id) {
                        Text("SKIPPED").font(.system(size: 9, weight: .heavy)).foregroundStyle(.orange)
                    }
                    Text(String(format: "%.1fs", result.duration)).font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
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
