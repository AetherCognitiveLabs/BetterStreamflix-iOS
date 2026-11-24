import SwiftUI

struct CloudSyncView: View {
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject private var sync = CloudSyncManager.shared
    @ObservedObject private var profiles = ProfileStore.shared
    @State private var projectURL = CloudSyncManager.shared.projectURL
    @State private var anonKey = CloudSyncManager.shared.anonKey
    @State private var email = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var isWorking = false

    @EnvironmentObject private var environment: AppEnvironment

    private var statusText: String {
        if !sync.isConfigured { return "Not set up" }
        if profiles.activeProfile.isKids { return "Unavailable on Kids profiles" }
        return sync.isSignedIn ? "Connected" : "Signed out"
    }

    private var statusColor: Color {
        sync.isConfigured && sync.isSignedIn ? Color(hex: 0x4CC9A6) : .white.opacity(0.45)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if sync.isConfigured {
                    accountCard
                }
                projectCard
                if let message = errorMessage ?? sync.lastMessage {
                    Label(message, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.65))
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.screenHorizontal)
            .padding(.bottom, 120)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .background { AppScreenBackground() }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: profiles.activeProfileID) { _, _ in sync.reloadForActiveProfile() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: sync.isSignedIn ? "checkmark.icloud.fill" : "icloud.fill")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 76, height: 76)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(LinearGradient(colors: [environment.theme.accentBright, environment.theme.accent.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing))
                )
                .shadow(color: environment.theme.accent.opacity(0.5), radius: 18, y: 6)
            VStack(alignment: .leading, spacing: 6) {
                Text("Cloud Sync")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
                Text("Keep your watchlist, watched episodes and resume positions in your own Supabase project.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(statusText).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(.white.opacity(0.07)))
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var accountCard: some View {
        if profiles.activeProfile.isKids {
            card(title: "Account") {
                Text("Kids profiles can't sign in to cloud sync.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.65))
            }
        } else if sync.isSignedIn {
            card(title: "Account") {
                HStack(spacing: 12) {
                    Text(String((sync.email ?? "A").prefix(1)).uppercased())
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(LinearGradient(colors: ProfilesView.avatarColors(profiles.activeProfile), startPoint: .topLeading, endPoint: .bottomTrailing)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sync.email ?? "Account").font(.body.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                        Text("Profile · \(profiles.activeProfile.displayName)").font(.caption).foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer()
                }
                HStack {
                    Label(sync.lastSyncAt.map { "Synced \($0.formatted(.relative(presentation: .named)))" } ?? "Not synced yet", systemImage: "clock.arrow.circlepath")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                    Spacer()
                }
                Button {
                    Task { await sync.syncNow(library: library) }
                } label: {
                    HStack(spacing: 8) {
                        if sync.isSyncing { ProgressView().tint(Color(hex: 0x11141C)) } else { Image(systemName: "arrow.triangle.2.circlepath") }
                        Text(sync.isSyncing ? "Syncing…" : "Sync Now")
                    }
                }
                .buttonStyle(AppPrimaryButtonStyle(glow: environment.theme.accent, minHeight: 48, verticalPadding: 12))
                .disabled(sync.isSyncing)
                Button("Sign Out", role: .destructive) { Task { await sync.signOut() } }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
        } else {
            card(title: "Sign in") {
                field {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                }
                field {
                    SecureField("Password", text: $password).textContentType(.password)
                }
                Button("Sign In") { authenticate(signUp: false) }
                    .buttonStyle(AppPrimaryButtonStyle(glow: environment.theme.accent, minHeight: 48, verticalPadding: 12))
                    .disabled(email.isEmpty || password.isEmpty || isWorking)
                Button("Create Account") { authenticate(signUp: true) }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .overlay(Capsule().stroke(.white.opacity(0.22), lineWidth: 1))
                    .disabled(email.isEmpty || password.count < 6 || isWorking)
            }
        }
    }

    private var projectCard: some View {
        card(title: "Supabase project", footnote: "Uses the same user_media_state table as the Android app, so both can share one project.") {
            field {
                TextField("https://your-project.supabase.co", text: $projectURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            }
            field {
                SecureField("Anon public key", text: $anonKey)
            }
            Button(sync.isConfigured ? "Update Project" : "Save Project") {
                do {
                    try sync.saveConfig(url: projectURL, anonKey: anonKey)
                    errorMessage = nil
                    DesignTokens.Haptics.selection()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            .buttonStyle(AppPrimaryButtonStyle(glow: environment.theme.accent, minHeight: 48, verticalPadding: 12))
            .disabled(projectURL.isEmpty || anonKey.isEmpty)
        }
    }

    private func card<Content: View>(title: String, footnote: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline.weight(.semibold)).foregroundStyle(.white)
            content()
            if let footnote {
                Text(footnote).font(.caption).foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(16)
        .appSurface(cornerRadius: DesignTokens.Radius.card)
    }

    private func field<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 46)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
    }

    private func authenticate(signUp: Bool) {
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                if signUp {
                    try await sync.signUp(email: email, password: password, library: library)
                } else {
                    try await sync.signIn(email: email, password: password, library: library)
                }
                password = ""
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
