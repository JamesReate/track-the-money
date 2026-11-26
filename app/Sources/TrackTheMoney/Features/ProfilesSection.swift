import SwiftUI
import TTMCore

// Profiles (docs/plans/PROFILES_PLAN.md): independent data sets on this device,
// one active at a time. Everything else in the app shows the active one. The
// engine owns the files and Keychain hygiene; this is only the list and sheets.

/// Small uppercase tag marking a test profile — the guard against mistaking
/// demo data for your real accounts (§4.5).
struct ProfileKindTag: View {
    let kind: ProfileKind
    var body: some View {
        if kind == .test {
            Text("TEST")
                .font(.system(.caption2, design: .default).weight(.bold))
                .tracking(1.2)
                .foregroundStyle(Brand.surface)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Brand.brass))
                .accessibilityLabel("Test profile")
        }
    }
}

/// Shown across the top of every tab while a test profile is active.
struct TestProfileBanner: View {
    let profile: ProfileSummary
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "flask")
            Text("Test profile · \(profile.name)").lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(Brand.surface)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .background(Brand.brass.ignoresSafeArea(edges: .top))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("testProfileBanner")
    }
}

/// Presentation state for the Profiles section. Lives in SettingsView and the
/// modifiers attach to the Form: a sheet/alert hung on a `Section` inside a
/// `Form` is applied per row and doesn't reliably present.
struct ProfilesUI {
    var creating = false
    var renaming: ProfileSummary?
    var renameText = ""
    var deleting: ProfileSummary?
}

struct ProfilesSection: View {
    @Bindable var model: AppModel
    @Binding var ui: ProfilesUI

    var body: some View {
        Section {
            ForEach(model.profiles) { profile in
                row(profile)
                    .contextMenu { menu(for: profile) }
            }
            Button("New profile…") { ui.creating = true }
                .disabled(model.isSyncing || model.isSwitchingProfile)
            Text("Each profile is a separate set of accounts, history, categories and rules — e.g. your real bank and a test bank. Switching never mixes them.")
                .font(.caption).foregroundStyle(Brand.slate)
        } header: { Eyebrow("Profile") }
        .listRowBackground(Brand.surface)
    }

    @ViewBuilder
    private func row(_ profile: ProfileSummary) -> some View {
        let content = HStack(spacing: 10) {
            Image(systemName: profile.isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(profile.isActive ? Brand.evergreen : Brand.slate)
            Text(profile.name).foregroundStyle(Brand.ink)
            ProfileKindTag(kind: profile.kind)
            Spacer()
            if profile.isActive {
                Text("Active").font(.caption).foregroundStyle(Brand.slate)
            }
        }
        .contentShape(Rectangle())

        if profile.isActive {
            content.accessibilityElement(children: .combine)
        } else {
            Button { Task { await model.switchProfile(to: profile.id) } } label: { content }
                .buttonStyle(.plain)
                .disabled(model.isSyncing || model.isSwitchingProfile)
                .accessibilityHint("Switch to this profile")
        }
    }

    @ViewBuilder
    private func menu(for profile: ProfileSummary) -> some View {
        if !profile.isActive {
            Button("Switch to “\(profile.name)”") { Task { await model.switchProfile(to: profile.id) } }
        }
        Button("Rename…") { ui.renameText = profile.name; ui.renaming = profile }
        if profile.kind == .test {
            Button("Mark as real data") { Task { await model.setProfileKind(id: profile.id, to: .real) } }
        } else {
            Button("Mark as test data") { Task { await model.setProfileKind(id: profile.id, to: .test) } }
        }
        if !profile.isActive {
            Button("Delete…", role: .destructive) { ui.deleting = profile }
        }
    }
}

struct ProfilesPresentations: ViewModifier {
    @Bindable var model: AppModel
    @Binding var ui: ProfilesUI

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $ui.creating) {
                NewProfileSheet { name, kind, seed in
                    ui.creating = false
                    Task { await model.createProfile(name: name, kind: kind, seed: seed) }
                } cancel: { ui.creating = false }
            }
            .alert("Rename profile",
                   isPresented: Binding(get: { ui.renaming != nil }, set: { if !$0 { ui.renaming = nil } })) {
                TextField("Name", text: $ui.renameText)
                Button("Rename") {
                    if let p = ui.renaming { Task { await model.renameProfile(id: p.id, to: ui.renameText) } }
                    ui.renaming = nil
                }
                Button("Cancel", role: .cancel) { ui.renaming = nil }
            }
            .confirmationDialog(
                "Delete “\(ui.deleting?.name ?? "")”?",
                isPresented: Binding(get: { ui.deleting != nil }, set: { if !$0 { ui.deleting = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete profile", role: .destructive) {
                    if let p = ui.deleting { Task { await model.deleteProfile(id: p.id) } }
                    ui.deleting = nil
                }
            } message: {
                Text("Its accounts, history and rules are removed from this device, along with its SimpleFIN link. Export a backup first if you might want it back.")
            }
    }
}

struct NewProfileSheet: View {
    let create: (String, ProfileKind, AppModel.ProfileSeed) -> Void
    let cancel: () -> Void

    @State private var seed: AppModel.ProfileSeed = .empty
    @State private var name = ""
    @State private var isTest = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Start with", selection: $seed) {
                        ForEach(AppModel.ProfileSeed.allCases) { Text($0.label).tag($0) }
                    }
                    Text(caption).font(.caption).foregroundStyle(Brand.slate)
                } header: { Eyebrow("Contents") }
                .listRowBackground(Brand.surface)

                Section {
                    TextField("Profile name", text: $name)
                        .accessibilityIdentifier("profileName")
                    Toggle("Test profile", isOn: $isTest)
                    Text("Test profiles show a banner on every screen so they’re never mistaken for your real accounts.")
                        .font(.caption).foregroundStyle(Brand.slate)
                } header: { Eyebrow("Profile") }
                .listRowBackground(Brand.surface)
            }
            .statementBackground()
            .inlineNavTitle("New profile")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        create(name, isTest ? .test : .real, seed)
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onChange(of: seed, initial: true) { _, new in
                // Follow the starting point until the user types their own name.
                if name.isEmpty || AppModel.ProfileSeed.allCases.map(\.suggestedName).contains(name) {
                    name = new.suggestedName
                }
                isTest = new.suggestedKind == .test
            }
        }
    }

    private var caption: String {
        switch seed {
        case .empty:      return "A blank profile. Add a SimpleFIN connection after it’s created."
        case .demoBank:   return "Connects to SimpleFIN’s public demo bank and syncs — the real sync path with made-up accounts. Needs a network connection."
        case .sampleData: return "Built-in demo accounts and history. No network, no connection."
        }
    }
}
