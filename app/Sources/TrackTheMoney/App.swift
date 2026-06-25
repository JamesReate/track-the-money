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
    @State private var selection = "networth"

    var body: some View {
        TabView(selection: $selection) {
            NetWorthView(model: model)
                .tabItem { Label("Net Worth", systemImage: "chart.line.uptrend.xyaxis") }.tag("networth")
            AccountsView(model: model)
                .tabItem { Label("Accounts", systemImage: "building.columns") }.tag("accounts")
            TransactionsView(model: model)
                .tabItem { Label("Transactions", systemImage: "list.bullet") }.tag("transactions")
            SpendingView(model: model)
                .tabItem { Label("Spending", systemImage: "chart.bar") }.tag("spending")
            RulesView(model: model)
                .tabItem { Label("Rules", systemImage: "slider.horizontal.3") }.tag("rules")
            RealEstateView(model: model)
                .tabItem { Label("Real Estate", systemImage: "house") }.tag("realestate")
            DebtInterestView(model: model)
                .tabItem { Label("Debt", systemImage: "creditcard") }.tag("debt")
            SettingsView(model: model)
                .tabItem { Label("Settings", systemImage: "gearshape") }.tag("settings")
        }
        .tint(Brand.evergreen)
        .task {
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-tab"), i + 1 < args.count { selection = args[i + 1] }
            if args.contains("-sampleData") { await model.loadSampleData() }
            await model.refresh()
        }
    }
}
