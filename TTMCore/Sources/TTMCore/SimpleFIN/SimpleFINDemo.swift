import Foundation

/// SimpleFIN's public demo bank (beta-bridge.simplefin.org). Its claim URL is
/// published and reusable, so it is safe to ship: claiming it yields the
/// well-known `demo:demo` Access URL, not anyone's real credentials. Used for
/// one-tap test profiles (PROFILES_PLAN §4.5) and the opt-in live tests.
public enum SimpleFINDemo {
    /// Base64 of `https://beta-bridge.simplefin.org/simplefin/claim/DEMO`.
    public static let setupToken =
        "aHR0cHM6Ly9iZXRhLWJyaWRnZS5zaW1wbGVmaW4ub3JnL3NpbXBsZWZpbi9jbGFpbS9ERU1P"
    public static let connectionName = "SimpleFIN demo bank"
}
