import Foundation

/// Fetches account + transaction data from a SimpleFIN Access URL.
/// The Access URL embeds Basic Auth credentials (`https://user:pass@host/...`).
public protocol SimpleFINClient: Sendable {
    func fetchAccounts(accessURL: URL, start: UnixTime?, end: UnixTime?, pending: Bool) async throws -> SFAccountSet
}

public struct LiveSimpleFINClient: SimpleFINClient {
    private let net: NetworkClient

    public init(net: NetworkClient) { self.net = net }

    public func fetchAccounts(accessURL: URL, start: UnixTime?, end: UnixTime?, pending: Bool) async throws -> SFAccountSet {
        guard var components = URLComponents(url: accessURL, resolvingAgainstBaseURL: false) else {
            throw TTMError.simplefin("invalid access URL")
        }

        // Split embedded Basic Auth out of the URL.
        let auth: BasicAuth?
        if let user = components.user, let password = components.password {
            auth = BasicAuth(user: user, password: password)
        } else {
            auth = nil
        }
        components.user = nil
        components.password = nil

        // {access}/accounts?start-date=&end-date=&pending=1
        var path = components.path
        if !path.hasSuffix("/accounts") { path += (path.hasSuffix("/") ? "" : "/") + "accounts" }
        components.path = path

        var query: [URLQueryItem] = []
        if let start { query.append(.init(name: "start-date", value: String(start))) }
        if let end { query.append(.init(name: "end-date", value: String(end))) }
        if pending { query.append(.init(name: "pending", value: "1")) }
        components.queryItems = query.isEmpty ? nil : query

        guard let url = components.url else { throw TTMError.simplefin("could not build request URL") }

        let data = try await net.get(url: url, basicAuth: auth)
        do {
            return try JSONDecoder().decode(SFAccountSet.self, from: data)
        } catch {
            throw TTMError.decoding("SFAccountSet: \(error)")
        }
    }
}
