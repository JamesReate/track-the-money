import SwiftUI
import TTMCore

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var setupToken = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Setup token", text: $setupToken, axis: .vertical)
                        .lineLimit(1...4)
                    Button("Add connection") {
                        let token = setupToken
                        setupToken = ""
                        Task { await model.claim(token: token) }
                    }
                    .disabled(setupToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: { Eyebrow("Add SimpleFIN connection") }
                .listRowBackground(Brand.surface)

                Section {
                    Button {
                        Task { await model.syncNow() }
                    } label: {
                        HStack {
                            Text("Sync now")
                            if model.isSyncing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(model.isSyncing)
                    Text("Auto-sync runs weekly. Your data stays on this device — we can’t see it.")
                        .font(.caption).foregroundStyle(Brand.slate)
                } header: { Eyebrow("Sync") }
                .listRowBackground(Brand.surface)

                Section {
                    Button("Load sample data") { Task { await model.loadSampleData() } }
                    Text("Explore the app with demo accounts before connecting a bank.")
                        .font(.caption).foregroundStyle(Brand.slate)
                } header: { Eyebrow("Try it") }
                .listRowBackground(Brand.surface)

                if !model.statusMessage.isEmpty {
                    Section { Text(model.statusMessage).font(.callout) }
                        header: { Eyebrow("Status") }
                        .listRowBackground(Brand.surface)
                }
            }
            .statementBackground()
            .navigationTitle("Settings")
        }
    }
}
