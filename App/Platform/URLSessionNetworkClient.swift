import Foundation
import TTMCore

/// NetworkClient backed by URLSession. The only place TTMCore's HTTP needs
/// touch the platform.
public struct URLSessionNetworkClient: NetworkClient {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func get(url: URL, basicAuth: BasicAuth?) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let basicAuth {
            let token = Data("\(basicAuth.user):\(basicAuth.password)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        return try await perform(request)
    }

    public func postJSON(url: URL, body: Data, bearer: String?) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        request.httpBody = body
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TTMError.network("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TTMError.network("HTTP \(http.statusCode)")
        }
        return data
    }
}
