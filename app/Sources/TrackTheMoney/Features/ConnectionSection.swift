import SwiftUI
import TTMCore

// The active profile's SimpleFIN connections, and whether each one actually
// works on this device (PROFILES_PLAN §4.7). The Access URL lives only in the
// Keychain (ADR-0013), so a profile loaded from a backup can have connection
// rows but no credential — this is where that becomes visible and fixable.

struct ConnectionSection: View {
    @Bindable var model: AppModel
    @State private var setupToken = ""
    /// Owned by SettingsView; the sheet is presented from the Form (see ProfilesUI).
    @Binding var reconnecting: ConnectionSummary?

    var body: some View {
        Section {
            if model.connections.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No SimpleFIN connection").foregroundStyle(Brand.ink)
                    Text("This profile isn’t linked to a bank. Paste a setup token from your SimpleFIN Bridge below.")
                        .font(.caption).foregroundStyle(Brand.slate)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("noConnection")
            } else {
                ForEach(model.connections) { conn in
                    ConnectionRow(connection: conn) { reconnecting = conn }
                }
            }

            TextField("Setup token", text: $setupToken, axis: .vertical)
                .lineLimit(1...4)
                // A vertical-axis TextField exposes its placeholder as
                // placeholderValue, not a label — UI tests need a handle.
                .accessibilityIdentifier("setupToken")
            Button {
                let token = setupToken
                Task {
                    // Keep the token on failure so a typo'd paste can be fixed.
                    if await model.claim(token: token) { setupToken = "" }
                }
            } label: {
                HStack {
                    Text(model.connections.isEmpty ? "Add connection" : "Add another connection")
                    if model.isClaiming {
                        Spacer()
                        ProgressView().controlSize(.small)
                        Text(model.isSyncing ? "Syncing…" : "Connecting…")
                            .font(.caption).foregroundStyle(Brand.slate)
                    }
                }
            }
            .disabled(setupToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || model.isSyncing || model.isClaiming)

            if let message = model.connectionMessage {
                Label(message.text, systemImage: message.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(message.isError ? Brand.clay : Brand.evergreen)
                    .accessibilityIdentifier("connectionMessage")
            }

            if model.hasSyncableConnection {
                Button {
                    Task { await model.syncNow() }
                } label: {
                    HStack {
                        Text("Sync now")
                        if model.isSyncing { Spacer(); ProgressView() }
                    }
                }
                .disabled(model.isSyncing || model.isClaiming)
            }
            Text("The connection is stored in this device’s Keychain, never in your data or backups. Your data stays on this device — we can’t see it.")
                .font(.caption).foregroundStyle(Brand.slate)
        } header: { Eyebrow("SimpleFIN connection") }
        .listRowBackground(Brand.surface)
    }
}

struct ReconnectPresentation: ViewModifier {
    @Bindable var model: AppModel
    @Binding var reconnecting: ConnectionSummary?

    func body(content: Content) -> some View {
        content.sheet(item: $reconnecting) { conn in
            ReconnectSheet(connection: conn) { token in
                reconnecting = nil
                Task { await model.reconnect(connectionId: conn.id, token: token) }
            } cancel: { reconnecting = nil }
        }
    }
}

private struct ConnectionRow: View {
    let connection: ConnectionSummary
    let reconnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(connection.org ?? connection.name).foregroundStyle(Brand.ink)
                Spacer()
                Text(label).font(.caption.weight(.semibold)).foregroundStyle(color)
            }
            Text(detail).font(.caption).foregroundStyle(Brand.slate)
            if connection.state.canReconnect {
                Button("Reconnect…", action: reconnect)
                    .font(.callout)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connection-\(connection.state.rawValue)")
    }

    private var label: String {
        switch connection.state {
        case .connected:         return "Connected"
        case .missingCredential: return "Not linked on this device"
        case .needsAuth:         return "Needs re-authorization"
        case .error:             return "Sync error"
        case .sample:            return "Sample data"
        }
    }

    private var color: Color {
        switch connection.state {
        case .connected:                 return Brand.evergreen
        case .sample:                    return Brand.slate
        case .missingCredential, .needsAuth, .error: return Brand.clay
        }
    }

    private var detail: String {
        var parts = ["\(connection.accountCount) account\(connection.accountCount == 1 ? "" : "s")"]
        switch connection.state {
        case .missingCredential:
            parts.append("no credential in this device’s Keychain — paste a new setup token to resume syncing")
        case .needsAuth:
            parts.append("the bridge refused the credential")
        case .error:
            if let e = connection.lastError { parts.append(e) }
        case .sample:
            parts.append("built-in demo, never syncs")
        case .connected:
            break
        }
        if connection.state != .sample {
            parts.append(connection.lastSyncedAt.map { "last synced \(Self.relative($0))" } ?? "never synced")
        }
        return parts.joined(separator: " · ")
    }

    private static func relative(_ t: UnixTime) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: Date(timeIntervalSince1970: TimeInterval(t)), relativeTo: Date())
    }
}

/// Paste a fresh setup token for an existing connection; accounts and history
/// carry on because the connection row is reused, not replaced.
private struct ReconnectSheet: View {
    let connection: ConnectionSummary
    let submit: (String) -> Void
    let cancel: () -> Void
    @State private var token = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Setup token", text: $token, axis: .vertical)
                        .lineLimit(1...4)
                        .accessibilityIdentifier("reconnectToken")
                    Text("Get a new setup token from your SimpleFIN Bridge. Your \(connection.accountCount) account\(connection.accountCount == 1 ? "" : "s") and their history stay as they are.")
                        .font(.caption).foregroundStyle(Brand.slate)
                } header: { Eyebrow("Reconnect \(connection.org ?? connection.name)") }
                .listRowBackground(Brand.surface)
            }
            .statementBackground()
            .inlineNavTitle("Reconnect")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Reconnect") { submit(token) }
                        .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
