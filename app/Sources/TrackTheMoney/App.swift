import SwiftUI
import TTMCore

@main
struct TrackTheMoneyApp: App {
    @State private var model: AppModel? = try? AppModel.live()

    var body: some Scene {
        WindowGroup {
            if let model {
                RootView(model: model)
            } else {
                Text("Failed to open local database.")
                    .foregroundStyle(.red)
                    .padding()
            }
        }
    }
}

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            NetWorthView(model: model)
                .tabItem { Label("Net Worth", systemImage: "chart.line.uptrend.xyaxis") }
            AccountsView(model: model)
                .tabItem { Label("Accounts", systemImage: "building.columns") }
            TransactionsView(model: model)
                .tabItem { Label("Transactions", systemImage: "list.bullet") }
            DebtInterestView(model: model)
                .tabItem { Label("Debt", systemImage: "creditcard") }
            SettingsView(model: model)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .task { await model.refresh() }
    }
}
