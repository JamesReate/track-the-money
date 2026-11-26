import SwiftUI
import TTMCore

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var profilesUI = ProfilesUI()
    @State private var reconnecting: ConnectionSummary?
    @State private var backupUI = BackupUI()

    var body: some View {
        NavigationStack {
            Form {
                // First, so the result of a switch / sync / restore is never below the fold.
                if !model.statusMessage.isEmpty {
                    Section { Text(model.statusMessage).font(.callout) }
                        header: { Eyebrow("Status") }
                        .listRowBackground(Brand.surface)
                }

                ProfilesSection(model: model, ui: $profilesUI)

                ConnectionSection(model: model, reconnecting: $reconnecting)

                BackupSection(model: model, ui: $backupUI)
            }
            .modifier(ProfilesPresentations(model: model, ui: $profilesUI))
            .modifier(ReconnectPresentation(model: model, reconnecting: $reconnecting))
            .modifier(BackupPresentations(model: model, ui: $backupUI))
            .statementBackground()
            .inlineNavTitle("Settings")
        }
    }
}
