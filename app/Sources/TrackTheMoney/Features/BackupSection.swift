import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers
import TTMCore

// The app half of backup & restore (docs/plans/DATA_PORTABILITY_PLAN.md): system
// pickers and a confirmation sheet. Every guarantee — validation, the safety
// copy, rollback — lives in TTMCore's BackupManager; nothing here decides
// whether a file is safe to restore.

extension UTType {
    /// Declared in project.yml's `info` block so Files/Finder recognise the
    /// extension. Falls back to a dynamic type when the app runs without an
    /// Info.plist (the headless `swift run` package build).
    static let ttmBackup = UTType(exportedAs: "money.trackthe.backup", conformingTo: .database)
}

/// Hands the exporter a file reference rather than its bytes, so a large store
/// is never loaded into memory just to be saved.
struct BackupFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .ttmBackup) { file in
            SentTransferredFile(file.url)
        }
    }
}

/// Picker state for the Backup section, owned by SettingsView so the pickers
/// and the confirm sheet attach to the Form, not the Section (see ProfilesUI).
struct BackupUI {
    var exporting = false
    var importing = false
}

struct BackupSection: View {
    @Bindable var model: AppModel
    @Binding var ui: BackupUI

    var body: some View {
        Section {
            Button("Export backup…") {
                Task {
                    await model.startExport()
                    ui.exporting = model.pendingExport != nil
                }
            }
            Button("Restore from backup…") { ui.importing = true }
                .disabled(model.isSyncing || model.isSwitchingProfile)

            if model.canUndoRestore {
                Button("Undo last restore", role: .destructive) {
                    Task { await model.undoRestore() }
                }
            }

            Text("One file with everything in this profile: accounts, transactions, categories, rules and history. A backup can be opened as its own profile or replace this one. Your SimpleFIN connection isn’t included — it stays in the Keychain.")
                .font(.caption).foregroundStyle(Brand.slate)
        } header: { Eyebrow("Backup") }
        .listRowBackground(Brand.surface)
    }
}

struct BackupPresentations: ViewModifier {
    @Bindable var model: AppModel
    @Binding var ui: BackupUI

    func body(content: Content) -> some View {
        content
            .fileExporter(
                isPresented: $ui.exporting,
                item: model.pendingExport.map(BackupFile.init(url:)),
                contentTypes: [.ttmBackup],
                defaultFilename: model.pendingExport?.lastPathComponent
            ) { result in
                model.finishExport(result)
            }
            // Content decides validity, not the extension — a store copied by hand
            // arrives as .db, so don't filter the picker down to our own type.
            .fileImporter(
                isPresented: $ui.importing,
                allowedContentTypes: [.ttmBackup, .database, .data]
            ) { result in
                switch result {
                case .success(let url): Task { await model.prepareRestore(from: url) }
                case .failure(let error):
                    let cancelled = (error as NSError).code == NSUserCancelledError
                    if !cancelled { model.statusMessage = "Couldn’t open that file: \(error.localizedDescription)" }
                }
            }
            .sheet(item: $model.pendingRestore) { pending in
                RestoreConfirmSheet(pending: pending,
                                    currentProfileName: model.activeProfile?.name,
                                    openAsProfile: { name, kind in
                                        Task { await model.openPendingAsProfile(name: name, kind: kind) }
                                    },
                                    replace: { Task { await model.confirmRestore() } },
                                    cancel: { model.cancelRestore() })
            }
    }
}

/// What's in the file, and the two things you can do with it: open it as a new
/// profile (non-destructive, the default) or replace the current profile.
struct RestoreConfirmSheet: View {
    let pending: PendingRestore
    let currentProfileName: String?
    let openAsProfile: (String, ProfileKind) -> Void
    let replace: () -> Void
    let cancel: () -> Void

    @State private var profileName: String
    @State private var isTest = false

    init(pending: PendingRestore, currentProfileName: String?,
         openAsProfile: @escaping (String, ProfileKind) -> Void,
         replace: @escaping () -> Void, cancel: @escaping () -> Void) {
        self.pending = pending
        self.currentProfileName = currentProfileName
        self.openAsProfile = openAsProfile
        self.replace = replace
        self.cancel = cancel
        _profileName = State(initialValue: pending.displayName)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    row("Transactions", "\(pending.info.transactions)")
                    row("Accounts", "\(pending.info.accounts)")
                    row("Categories", "\(pending.info.categories)")
                    row("Rules", "\(pending.info.rules)")
                    if pending.info.properties > 0 { row("Properties", "\(pending.info.properties)") }
                    if let newest = pending.info.newestTransactionAt {
                        row("Data through", Self.date.string(from: Date(timeIntervalSince1970: TimeInterval(newest))))
                    }
                    row("File size", Self.size.string(fromByteCount: pending.info.fileSizeBytes))
                } header: { Eyebrow("This backup contains") }
                .listRowBackground(Brand.surface)

                if pending.info.needsMigration {
                    Section {
                        Text("This backup is from an older version — it’ll be upgraded as it’s opened.")
                            .font(.caption).foregroundStyle(Brand.slate)
                    }
                    .listRowBackground(Brand.surface)
                }

                Section {
                    TextField("Profile name", text: $profileName)
                        .accessibilityIdentifier("importProfileName")
                    Toggle("Test profile", isOn: $isTest)
                    Button("Open as new profile") { openAsProfile(profileName, isTest ? .test : .real) }
                        .disabled(profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text("Keeps everything you have now; switch between them in Settings.")
                        .font(.caption).foregroundStyle(Brand.slate)
                } header: { Eyebrow("Open as a new profile") }
                .listRowBackground(Brand.surface)

                Section {
                    Button("Replace \(currentProfileName.map { "“\($0)”" } ?? "my data")", role: .destructive, action: replace)
                    Text("Replaces everything in the current profile with this backup. You can undo it right afterwards.")
                        .font(.caption).foregroundStyle(Brand.slate)
                } header: { Eyebrow("Or replace this profile") }
                .listRowBackground(Brand.surface)
            }
            .statementBackground()
            .inlineNavTitle("Open backup")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(Brand.slate)
        }
    }

    private static let date: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    private static let size: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()
}
