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

    var body: some View {
        Form {
            Section {
                TextField("https://your-project.supabase.co", text: $projectURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                SecureField("Anon public key", text: $anonKey)
                Button("Save project") {
                    do {
                        try sync.saveConfig(url: projectURL, anonKey: anonKey)
                        errorMessage = nil
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .disabled(projectURL.isEmpty || anonKey.isEmpty)
            } header: {
                Text("Supabase project")
            } footer: {
                Text("Uses the same user_media_state table as the Android app, so both can share one project.")
            }

            if sync.isConfigured {
                if profiles.activeProfile.isKids {
                    Section { Text("Kids profiles can't sign in to cloud sync.").foregroundStyle(.secondary) }
                } else if sync.isSignedIn {
                    Section {
                        LabeledContent("Signed in", value: sync.email ?? "Account")
                        LabeledContent("Profile", value: profiles.activeProfile.displayName)
                        if let date = sync.lastSyncAt {
                            LabeledContent("Last sync", value: date.formatted(date: .abbreviated, time: .shortened))
                        }
                        Button {
                            Task { await sync.syncNow(library: library) }
                        } label: {
                            HStack {
                                Text("Sync now")
                                if sync.isSyncing { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(sync.isSyncing)
                        Button("Sign out", role: .destructive) { Task { await sync.signOut() } }
                    } header: {
                        Text("Account")
                    } footer: {
                        Text("Syncs this profile's watchlist, watched episodes and resume positions.")
                    }
                } else {
                    Section("Account") {
                        TextField("Email", text: $email)
                            .textContentType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.emailAddress)
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                        Button("Sign in") { authenticate(signUp: false) }
                            .disabled(email.isEmpty || password.isEmpty || isWorking)
                        Button("Create account") { authenticate(signUp: true) }
                            .disabled(email.isEmpty || password.count < 6 || isWorking)
                    }
                }
            }

            if let message = errorMessage ?? sync.lastMessage {
                Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Cloud Sync")
        .onChange(of: profiles.activeProfileID) { _, _ in sync.reloadForActiveProfile() }
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
