import Foundation

// Profiles: several independent data sets on one device, one active at a time
// (docs/plans/PROFILES_PLAN.md). Each profile is its own SQLite store in its own
// folder; a small JSON registry beside them names them and records which is
// active. The registry is a plain file, not a table, because it must be readable
// before any store is open.
//
//   <root>/profiles.json
//   <root>/profiles/<id>/ttm.db   (+ -wal/-shm, + ttm.db.pre-restore)
//
// Pure Foundation file work, like BackupManager — no UI, no Keychain. Secrets
// stay keyed per connection in the SecretStore, so a profile's connection keeps
// working however often you switch away and back.

/// Display hint only — drives the "test profile" badge, never behavior.
public enum ProfileKind: String, Codable, Sendable, CaseIterable {
    case real
    case test
}

public struct ProfileSummary: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let kind: ProfileKind
    public let createdAt: UnixTime
    public let lastOpenedAt: UnixTime?
    public let isActive: Bool

    public init(id: String, name: String, kind: ProfileKind, createdAt: UnixTime,
                lastOpenedAt: UnixTime?, isActive: Bool) {
        self.id = id; self.name = name; self.kind = kind
        self.createdAt = createdAt; self.lastOpenedAt = lastOpenedAt; self.isActive = isActive
    }
}

public enum ProfileError: Error, Equatable, LocalizedError {
    case notFound
    case emptyName
    case cannotDeleteActive
    case cannotDeleteLast
    case unavailable
    case registryDamaged(String)

    public var errorDescription: String? {
        switch self {
        case .notFound:                return "That profile no longer exists."
        case .emptyName:               return "Give the profile a name."
        case .cannotDeleteActive:      return "Switch to another profile before deleting this one."
        case .cannotDeleteLast:        return "You can't delete your only profile."
        case .unavailable:             return "Profiles aren't available for this store."
        case .registryDamaged(let why): return "The profile list couldn't be read (\(why))."
        }
    }
}

/// Owns the on-disk layout and the registry. Not thread-safe on its own;
/// `LocalCore` serializes access.
final class ProfileManager {
    struct Entry: Codable, Equatable {
        var id: String
        var name: String
        var kind: ProfileKind
        var createdAt: Int64
        var lastOpenedAt: Int64?
    }

    struct Registry: Codable, Equatable {
        var activeId: String
        var profiles: [Entry]
    }

    static let registryFile = "profiles.json"
    static let profilesDir = "profiles"
    static let storeFile = "ttm.db"
    /// What a pre-profiles install's store is called once it's adopted (§5 D5a).
    static let legacyProfileName = "My data"

    let root: URL
    private let clock: Clock
    private(set) var registry: Registry

    /// Open (or initialise) the profile layout under `root`. Adopts a
    /// pre-profiles `<root>/ttm.db` as the first profile, and creates an empty
    /// "My data" profile if there's nothing at all. Idempotent.
    init(root: URL, clock: Clock) throws {
        self.root = root
        self.clock = clock
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent(Self.profilesDir, isDirectory: true),
                               withIntermediateDirectories: true)

        let registryURL = root.appendingPathComponent(Self.registryFile)
        if fm.fileExists(atPath: registryURL.path) {
            do {
                registry = try JSONDecoder().decode(Registry.self, from: Data(contentsOf: registryURL))
            } catch {
                throw ProfileError.registryDamaged(String(describing: error))
            }
        } else {
            registry = Registry(activeId: "", profiles: [])
        }

        try adoptLegacyStoreIfPresent()

        if registry.profiles.isEmpty {
            let entry = try makeEntry(name: Self.legacyProfileName, kind: .real)
            registry.profiles.append(entry)
            registry.activeId = entry.id
        }
        // A hand-edited or half-written registry might point nowhere.
        if !registry.profiles.contains(where: { $0.id == registry.activeId }) {
            registry.activeId = registry.profiles[0].id
        }
        try save()
    }

    // MARK: Queries

    var activeId: String { registry.activeId }

    func storePath(for id: String) -> String {
        directory(for: id).appendingPathComponent(Self.storeFile).path
    }

    var activeStorePath: String { storePath(for: registry.activeId) }

    func summaries() -> [ProfileSummary] {
        registry.profiles.map(summary)
    }

    func summary(id: String) throws -> ProfileSummary {
        guard let entry = registry.profiles.first(where: { $0.id == id }) else { throw ProfileError.notFound }
        return summary(entry)
    }

    func entry(named name: String) -> Entry? {
        registry.profiles.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: Mutations

    /// Register a new, empty profile folder. The store itself is created the
    /// first time it's opened (migrations + seed run then).
    @discardableResult
    func create(name: String, kind: ProfileKind) throws -> Entry {
        let entry = try makeEntry(name: name, kind: kind)
        registry.profiles.append(entry)
        try save()
        return entry
    }

    /// Register a profile whose store file was already placed at `storePath(for:)`.
    /// Used by import, which needs the folder before the entry exists.
    func register(id: String, name: String, kind: ProfileKind) throws -> Entry {
        let entry = Entry(id: id, name: try Self.clean(name), kind: kind,
                          createdAt: clock.now(), lastOpenedAt: nil)
        registry.profiles.append(entry)
        try save()
        return entry
    }

    func setActive(_ id: String) throws {
        guard let i = registry.profiles.firstIndex(where: { $0.id == id }) else { throw ProfileError.notFound }
        registry.activeId = id
        registry.profiles[i].lastOpenedAt = clock.now()
        try save()
    }

    func rename(_ id: String, to name: String) throws {
        guard let i = registry.profiles.firstIndex(where: { $0.id == id }) else { throw ProfileError.notFound }
        registry.profiles[i].name = try Self.clean(name)
        try save()
    }

    func setKind(_ id: String, to kind: ProfileKind) throws {
        guard let i = registry.profiles.firstIndex(where: { $0.id == id }) else { throw ProfileError.notFound }
        registry.profiles[i].kind = kind
        try save()
    }

    /// Unregister and remove the profile's folder. Refuses the active profile
    /// (its store is open) and the last one (the app always has a store).
    func delete(_ id: String) throws {
        guard registry.profiles.contains(where: { $0.id == id }) else { throw ProfileError.notFound }
        guard id != registry.activeId else { throw ProfileError.cannotDeleteActive }
        guard registry.profiles.count > 1 else { throw ProfileError.cannotDeleteLast }
        registry.profiles.removeAll { $0.id == id }
        try save()   // registry first: a leftover folder is harmless, a dangling entry isn't
        try? FileManager.default.removeItem(at: directory(for: id))
    }

    /// A fresh profile id with its folder created, not yet registered.
    func reserveDirectory() throws -> String {
        let id = UUID().uuidString.lowercased()
        try FileManager.default.createDirectory(at: directory(for: id), withIntermediateDirectories: true)
        return id
    }

    func discardDirectory(_ id: String) {
        try? FileManager.default.removeItem(at: directory(for: id))
    }

    // MARK: Internals

    private func directory(for id: String) -> URL {
        root.appendingPathComponent(Self.profilesDir, isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }

    private func summary(_ e: Entry) -> ProfileSummary {
        ProfileSummary(id: e.id, name: e.name, kind: e.kind, createdAt: e.createdAt,
                       lastOpenedAt: e.lastOpenedAt, isActive: e.id == registry.activeId)
    }

    private func makeEntry(name: String, kind: ProfileKind) throws -> Entry {
        let id = try reserveDirectory()
        return Entry(id: id, name: try Self.clean(name), kind: kind, createdAt: clock.now(), lastOpenedAt: nil)
    }

    private static func clean(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProfileError.emptyName }
        return trimmed
    }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(registry)
        try data.write(to: root.appendingPathComponent(Self.registryFile), options: .atomic)
    }

    /// Move a pre-profiles `<root>/ttm.db` (+ sidecars + undo copy) into a
    /// profile folder. Runs before any store is opened, so the files are
    /// cleanly closed.
    ///
    /// Crash-safe by ordering: the target profile is registered first, the
    /// sidecars move before the main file, and the main file moves last. So
    /// while `<root>/ttm.db` still exists the job is unfinished, and a retry
    /// reuses the registered-but-empty legacy profile rather than minting a
    /// second one.
    private func adoptLegacyStoreIfPresent() throws {
        let fm = FileManager.default
        let legacy = root.appendingPathComponent(Self.storeFile)
        guard fm.fileExists(atPath: legacy.path) else { return }

        let entry: Entry
        if let pending = registry.profiles.first(where: {
            $0.name == Self.legacyProfileName && !fm.fileExists(atPath: storePath(for: $0.id))
        }) {
            entry = pending
        } else {
            entry = try makeEntry(name: Self.legacyProfileName, kind: .real)
            registry.profiles.insert(entry, at: 0)
        }
        registry.activeId = entry.id
        try save()

        let target = storePath(for: entry.id)
        try fm.createDirectory(at: directory(for: entry.id), withIntermediateDirectories: true)
        for suffix in ["-wal", "-shm", BackupManager.preRestoreSuffix, ""] {
            let from = legacy.path + suffix
            guard fm.fileExists(atPath: from) else { continue }
            try? fm.removeItem(atPath: target + suffix)
            try fm.moveItem(atPath: from, toPath: target + suffix)
        }
    }
}
