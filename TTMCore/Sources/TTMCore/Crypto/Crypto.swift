import Foundation

// End-to-end crypto for the PAID cloud relay (TECH_DESIGN §9). Each syncable
// record gets a per-record AES-256-GCM data key; that data key is HPKE-sealed
// (X25519, Apple CryptoKit) to EACH household member's public key. The server
// stores ciphertext + wrapped keys only — it holds no private key.
//
// Standardize on algorithms with first-class Rust crates (aes-gcm, rust-hpke)
// so records sealed by the Swift build unseal identically after the Rust port.
//
// TODO(M2.9): implement with CryptoKit (Curve25519 + HPKE). Private key lives in
// the device Keychain, synced via iCloud Keychain, with an Argon2id passphrase
// as recovery. Group join/leave ⇒ re-wrap data keys client-side.

public struct SealedRecord: Sendable {
    public let id: String
    public let type: String
    public let ciphertext: Data
    public let wrappedKeys: [WrappedKey]
    public let updatedAt: UnixTime
    public let deleted: Bool
}

public struct WrappedKey: Sendable {
    public let keyId: String      // recipient member/device public-key id
    public let wrapped: Data
}

public protocol RecordSealer: Sendable {
    func seal(id: String, type: String, plaintext: Data, recipients: [WrappedKeyRecipient], updatedAt: UnixTime) throws -> SealedRecord
    func open(_ record: SealedRecord) throws -> Data
}

public struct WrappedKeyRecipient: Sendable {
    public let keyId: String
    public let publicKey: Data
    public init(keyId: String, publicKey: Data) {
        self.keyId = keyId
        self.publicKey = publicKey
    }
}
