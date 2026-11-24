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

    @EnvironmentObject private var environment: AppEnvironment
    @State private var showsAddSheet = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 18, alignment: .top), count: 3)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Who's watching?")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Each profile keeps its own watchlist, history and progress.")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.horizontal, DesignTokens.Spacing.screenHorizontal)

                LazyVGrid(columns: columns, spacing: 22) {
                    ForEach(store.profiles) { profile in
                        Button { attemptSwitch(to: profile) } label: { avatarTile(profile) }
                            .buttonStyle(PressablePosterButtonStyle())
                            .contextMenu {
                                if profile.id != UserProfile.defaultID {
                                    Button("Delete Profile", systemImage: "trash", role: .destructive) { guarded(profile, .delete) }
                                }
                            }
                    }
                    Button { showsAddSheet = true } label: { addTile }
                        .buttonStyle(PressablePosterButtonStyle())
                }
                .padding(.horizontal, DesignTokens.Spacing.screenHorizontal)

                activeSettings
                    .padding(.horizontal, DesignTokens.Spacing.screenHorizontal)
            }
            .padding(.top, 8)
            .padding(.bottom, 120)
        }
        .scrollIndicators(.hidden)
        .background { AppScreenBackground() }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsAddSheet) { addSheet }
        .alert(pinTitle, isPresented: Binding(get: { pinPrompt != nil }, set: { if !$0 { pinPrompt = nil } })) {
            SecureField("PIN", text: $pinEntry).keyboardType(.numberPad)
            Button("OK") { completePIN() }
            Button("Cancel", role: .cancel) { pinEntry = "" }
        }
    }

    static func avatarColors(_ profile: UserProfile) -> [Color] {
        if profile.isKids { return [Color(hex: 0xFFB547), Color(hex: 0xE5603B)] }
        let palette: [[UInt32]] = [[0x397BFF, 0x1B2E73], [0x765BFF, 0x2D1F6B], [0x20C7C5, 0x0E4F57], [0xC85C9E, 0x55204A], [0x4CC9A6, 0x165244]]
        let index = profile.id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % palette.count
        return palette[index].map { Color(hex: $0) }
    }

    private func avatar(_ profile: UserProfile, size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient(colors: Self.avatarColors(profile), startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: profile.avatarSymbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }

    private func avatarTile(_ profile: UserProfile) -> some View {
        let active = profile.id == store.activeProfileID
        return VStack(spacing: 8) {
            avatar(profile, size: 92)
                .overlay {
                    RoundedRectangle(cornerRadius: 92 * 0.28 + 4, style: .continuous)
                        .stroke(active ? environment.theme.accentBright : .clear, lineWidth: 2.5)
                        .padding(-5)
                }
                .overlay(alignment: .bottomTrailing) {
                    if profile.pinHash != nil {
                        Image(systemName: "lock.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(.black.opacity(0.6)))
                            .offset(x: 4, y: 4)
                    }
                }
                .shadow(color: active ? environment.theme.accent.opacity(0.5) : .black.opacity(0.35), radius: 12, y: 5)
            Text(profile.displayName)
                .font(.subheadline.weight(active ? .bold : .medium))
                .foregroundStyle(active ? .white : .white.opacity(0.75))
                .lineLimit(1)
            if profile.isKids {
                Text("KIDS \(profile.maxAgeRating ?? 12)+")
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(0.6)
                    .foregroundStyle(Color(hex: 0x11141C))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color(hex: 0xFFB547)))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var addTile: some View {
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 92 * 0.28, style: .continuous)
                .strokeBorder(.white.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .frame(width: 92, height: 92)
                .overlay {
                    Image(systemName: "plus").font(.system(size: 30, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                }
            Text("Add Profile")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
    }

    private var addSheet: some View {
        let preview = UserProfile(id: newName.isEmpty ? "new" : newName, displayName: newName, avatarSymbol: newIsKids ? "teddybear.fill" : "person.fill", isKids: newIsKids)
        return VStack(spacing: 22) {
            avatar(preview, size: 104)
                .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
                .padding(.top, 28)
            Text("New Profile").font(.title2.weight(.bold)).foregroundStyle(.white)
            VStack(spacing: 0) {
                TextField("Name", text: $newName)
                    .padding(16)
                    .foregroundStyle(.white)
                Divider().overlay(AppTheme.border)
                Toggle("Kids profile", isOn: $newIsKids)
                    .padding(16)
                    .tint(environment.theme.accent)
            }
            .appSurface(cornerRadius: DesignTokens.Radius.card)
            Button("Create Profile") {
                store.create(name: newName, isKids: newIsKids)
                newName = ""
                newIsKids = false
                showsAddSheet = false
            }
            .buttonStyle(AppPrimaryButtonStyle(glow: environment.theme.accent))
            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            Spacer()
        }
        .padding(.horizontal, DesignTokens.Spacing.screenHorizontal)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { AppScreenBackground() }
        .presentationDetents([.medium])
        .presentationCornerRadius(DesignTokens.Radius.sheet)
    }

    private var activeSettings: some View {
        let active = store.activeProfile
        return VStack(alignment: .leading, spacing: 12) {
            Text("\(active.displayName)'s settings")
                .font(DesignTokens.Typography.shelfTitle)
                .foregroundStyle(.white)
            VStack(spacing: 0) {
                settingRow("Kids profile", subtitle: "Hides mature genres in search and trending", systemImage: "figure.and.child.holdinghands") {
                    Toggle("", isOn: Binding(
                        get: { active.isKids },
                        set: { value in
                            if !value && active.pinHash != nil { guarded(active, .switchTo, then: { store.setKids(active.id, false) }) }
                            else { store.setKids(active.id, value) }
                        }
                    ))
                    .labelsHidden()
                    .tint(environment.theme.accent)
                }
                if active.isKids {
                    Divider().overlay(AppTheme.border).padding(.leading, 58)
                    settingRow("Maximum age", subtitle: nil, systemImage: "shield.lefthalf.filled") {
                        Picker("Maximum age", selection: Binding(
                            get: { active.maxAgeRating ?? 12 },
                            set: { store.setMaxAgeRating(active.id, $0) }
                        )) {
                            ForEach(ProfileStore.kidsAgeOptions, id: \.self) { Text("\($0)+").tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 170)
                    }
                }
                Divider().overlay(AppTheme.border).padding(.leading, 58)
                Button {
                    pinPrompt = PINPrompt(profile: active, action: .setPIN)
                } label: {
                    settingRow(active.pinHash == nil ? "Set PIN" : "Change PIN", subtitle: "Required to switch into this profile", systemImage: "lock.fill") {
                        Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.35))
                    }
                }
                .buttonStyle(.plain)
                if active.pinHash != nil {
                    Divider().overlay(AppTheme.border).padding(.leading, 58)
                    Button {
                        guarded(active, .switchTo, then: { store.setPIN(active.id, nil) })
                    } label: {
                        settingRow("Remove PIN", subtitle: nil, systemImage: "lock.open.fill", destructive: true) { EmptyView() }
                    }
                    .buttonStyle(.plain)
                }
            }
            .appSurface(cornerRadius: DesignTokens.Radius.card)
        }
    }

    private func settingRow<Accessory: View>(
        _ title: String,
        subtitle: String?,
        systemImage: String,
        destructive: Bool = false,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(destructive ? .red : environment.theme.accentBright)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.06)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(destructive ? .red : .white)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.55))
                }
            }
            Spacer(minLength: 8)
            accessory()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
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
