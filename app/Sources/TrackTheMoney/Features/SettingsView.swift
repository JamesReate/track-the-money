import SwiftUI
import TTMCore

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var setupToken = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Add SimpleFIN connection") {
                    TextField("Setup token", text: $setupToken, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                    Button("Add connection") {
                        let token = setupToken
                        setupToken = ""
                        Task { await model.claim(token: token) }
                    }
                    .disabled(setupToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section("Sync") {
                    Button {
                        Task { await model.syncNow() }
                    } label: {
                        HStack {
                            Text("Sync now")
                            if model.isSyncing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(model.isSyncing)
                    Text("Auto-sync runs weekly. Your data stays on this device.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if !model.statusMessage.isEmpty {
                    Section("Status") { Text(model.statusMessage).font(.callout) }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
