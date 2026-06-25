import Foundation

// Injected platform services. TTMCore depends only on these protocols, never on
// Keychain / URLSession / Date directly — so the engines are testable and the
// future Rust port (TECH_DESIGN §13) can supply native trait implementations.

/// Monotonic-ish wall clock in unix seconds (UTC). Injected for testability.
public protocol Clock: Sendable {
    func now() -> UnixTime
}

public struct SystemClock: Clock {
    public init() {}
    public func now() -> UnixTime { Time.unix(Date()) }
}

/// Secret storage for the SimpleFIN Access URL. Backed by Keychain on Apple
/// platforms; never persisted in the app DB and never sent to any backend.
public protocol SecretStore: Sendable {
    func read(ref: String) throws -> String?
    func write(_ value: String, ref: String) throws
    func delete(ref: String) throws
}

/// Minimal networking surface the SimpleFIN client and SyncClient depend on.
public protocol NetworkClient: Sendable {
    func get(url: URL, basicAuth: BasicAuth?) async throws -> Data
    func postJSON(url: URL, body: Data, bearer: String?) async throws -> Data
}

public struct BasicAuth: Sendable {
    public let user: String
    public let password: String
    public init(user: String, password: String) {
        self.user = user
        self.password = password
    }
}

public enum TTMError: Error, Equatable {
    case simplefin(String)
    case decoding(String)
    case network(String)
    case notFound
    case crypto(String)
}
