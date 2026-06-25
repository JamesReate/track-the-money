import SwiftUI
import TTMCore

@main
struct TrackTheMoneyApp: App {
    // Native implementations of TTMCore's injected protocols live here, in the
    // app layer only. A concrete CoreFacade (DB + sync + rules) gets wired in
    // once Milestone 1 implementations land.
    private let secrets = KeychainSecretStore()
    private let network = URLSessionNetworkClient()
    private let clock = SystemClock()

    var body: some Scene {
        WindowGroup {
            NetWorthView()
        }
    }
}
