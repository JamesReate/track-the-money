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

struct BackupSection: View {
    @Bindable var model: AppModel
    @State private var exporting = false
    @State private var importing = false

    var body: some View {
        Section {
            Button("Export backup…") {
                Task {
                    await model.startExport()
                    exporting = model.pendingExport != nil
                }
            }
            Button("Restore from backup…") { importing = true }

            if model.canUndoRestore {
                Button("Undo last restore", role: .destructive) {
                    Task { await model.undoRestore() }
                }
            }

            Text("One file with everything: accounts, transactions, categories, rules and history. Your SimpleFIN connection isn’t included — it stays in the Keychain.")
                .font(.caption).foregroundStyle(Brand.slate)
        } header: { Eyebrow("Backup") }
        .listRowBackground(Brand.surface)
        .fileExporter(
            isPresented: $exporting,
            item: model.pendingExport.map(BackupFile.init(url:)),
            contentTypes: [.ttmBackup],
            defaultFilename: model.pendingExport?.lastPathComponent
        ) { result in
            model.finishExport(result)
        }
        // Content decides validity, not the extension — a store copied by hand
        // arrives as .db, so don't filter the picker down to our own type.
        .fileImporter(
            isPresented: $importing,
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
                                confirm: { Task { await model.confirmRestore() } },
                                cancel: { model.cancelRestore() })
        }
    }
}

/// What's in the file and what replacing costs, before anything is touched.
struct RestoreConfirmSheet: View {
    let pending: PendingRestore
    let confirm: () -> Void
    let cancel: () -> Void

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

                Section {
                    Text("Restoring replaces everything currently in the app. You can undo it right afterwards.")
                        .font(.callout)
                    if pending.info.needsMigration {
                        Text("This backup is from an older version — it’ll be upgraded as it’s restored.")
                            .font(.caption).foregroundStyle(Brand.slate)
                    }
                }
                .listRowBackground(Brand.surface)

                Section {
                    Button("Replace my data", role: .destructive, action: confirm)
                }
                .listRowBackground(Brand.surface)
            }
            .statementBackground()
            .inlineNavTitle("Restore backup")
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
