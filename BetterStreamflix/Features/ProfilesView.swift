import SwiftUI

struct ProfilesView: View {
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject private var store = ProfileStore.shared
    @State private var newName = ""
    @State private var newIsKids = false
    @State private var pinPrompt: PINPrompt?
    @State private var pinEntry = ""

    private enum PINAction { case switchTo, setPIN, delete }
    private struct PINPrompt: Identifiable {
        let id = UUID()
        let profile: UserProfile
        let action: PINAction
    }

    var body: some View {
        List {
            Section("Profiles") {
                ForEach(store.profiles) { profile in
                    Button { attemptSwitch(to: profile) } label: { row(profile) }
                        .buttonStyle(.plain)
                        .swipeActions {
                            if profile.id != UserProfile.defaultID {
                                Button("Delete", role: .destructive) { guarded(profile, .delete) }
                            }
                        }
                }
            }
            Section("Add profile") {
                TextField("Name", text: $newName)
                Toggle("Kids profile", isOn: $newIsKids)
                Button("Add") {
                    store.create(name: newName, isKids: newIsKids)
                    newName = ""
                    newIsKids = false
                }
            }
            activeSettings
        }
        .navigationTitle("Profiles")
        .alert(pinTitle, isPresented: Binding(get: { pinPrompt != nil }, set: { if !$0 { pinPrompt = nil } })) {
            SecureField("PIN", text: $pinEntry).keyboardType(.numberPad)
            Button("OK") { completePIN() }
            Button("Cancel", role: .cancel) { pinEntry = "" }
        }
    }

    @ViewBuilder private var activeSettings: some View {
        let active = store.activeProfile
        Section {
            Toggle("Kids profile", isOn: Binding(
                get: { active.isKids },
                set: { value in
                    if !value && active.pinHash != nil { guarded(active, .switchTo, then: { store.setKids(active.id, false) }) }
                    else { store.setKids(active.id, value) }
                }
            ))
            if active.isKids {
                Picker("Maximum age rating", selection: Binding(
                    get: { active.maxAgeRating ?? 12 },
                    set: { store.setMaxAgeRating(active.id, $0) }
                )) {
                    ForEach(ProfileStore.kidsAgeOptions, id: \.self) { Text("\($0)+").tag($0) }
                }
            }
            Button(active.pinHash == nil ? "Set PIN" : "Change PIN") {
                pinPrompt = PINPrompt(profile: active, action: .setPIN)
            }
            if active.pinHash != nil {
                Button("Remove PIN", role: .destructive) { guarded(active, .switchTo, then: { store.setPIN(active.id, nil) }) }
            }
        } header: {
            Text("Active: \(active.displayName)")
        } footer: {
            Text("Each profile has its own watchlist, history and progress. Kids profiles hide mature genres in search and trending.")
        }
    }

    private func row(_ profile: UserProfile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: profile.avatarSymbol)
                .font(.title2)
                .foregroundStyle(profile.isKids ? .orange : .accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.displayName).font(.body.weight(.semibold))
                Text(profile.isKids ? "Kids · up to \(profile.maxAgeRating ?? 12)+" : "Standard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if profile.pinHash != nil { Image(systemName: "lock.fill").foregroundStyle(.secondary) }
            if profile.id == store.activeProfileID { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
        }
        .contentShape(Rectangle())
    }

    @State private var pendingAction: (() -> Void)?

    private var pinTitle: String {
        guard let prompt = pinPrompt else { return "" }
        return prompt.action == .setPIN ? "New PIN for \(prompt.profile.displayName)" : "PIN for \(prompt.profile.displayName)"
    }

    private func attemptSwitch(to profile: UserProfile) {
        guard profile.id != store.activeProfileID else { return }
        // Leaving a PIN-locked Kids profile needs that profile's PIN; entering a locked profile needs its own.
        let active = store.activeProfile
        if active.isKids, active.pinHash != nil {
            guarded(active, .switchTo, then: { switchOrUnlock(profile) })
        } else {
            switchOrUnlock(profile)
        }
    }

    private func switchOrUnlock(_ profile: UserProfile) {
        if store.requiresPIN(toSwitchTo: profile.id) {
            guarded(profile, .switchTo, then: { store.switchTo(profile.id, library: library) })
        } else {
            store.switchTo(profile.id, library: library)
        }
    }

    private func guarded(_ profile: UserProfile, _ action: PINAction, then perform: (() -> Void)? = nil) {
        let work = perform ?? { if action == .delete { store.delete(profile.id, library: library) } }
        guard profile.pinHash != nil else { work(); return }
        pendingAction = work
        pinPrompt = PINPrompt(profile: profile, action: action)
    }

    private func completePIN() {
        defer { pinEntry = ""; pinPrompt = nil }
        guard let prompt = pinPrompt else { return }
        if prompt.action == .setPIN {
            store.setPIN(prompt.profile.id, pinEntry)
            return
        }
        guard store.verifyPIN(prompt.profile.id, pinEntry) else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            pendingAction = nil
            return
        }
        let action = pendingAction
        pendingAction = nil
        // Run after the alert dismisses so a follow-up PIN prompt can present.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { action?() }
    }
}
