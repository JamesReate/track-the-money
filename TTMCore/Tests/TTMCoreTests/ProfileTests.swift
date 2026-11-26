import XCTest
@testable import TTMCore

/// Profiles (docs/plans/PROFILES_PLAN.md): independent stores on one device,
/// switched in place, with each profile owning its own Keychain items, plus
/// the connection-visibility surface (§4.7).
final class ProfileTests: XCTestCase {
    private struct C: Clock { func now() -> UnixTime { 1_700_000_000 } }

    private final class Secrets: SecretStore, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: String] = [:]
        func read(ref: String) throws -> String? { lock.lock(); defer { lock.unlock() }; return storage[ref] }
        func write(_ value: String, ref: String) throws { lock.lock(); storage[ref] = value; lock.unlock() }
        func delete(ref: String) throws { lock.lock(); storage[ref] = nil; lock.unlock() }
        var refs: Set<String> { lock.lock(); defer { lock.unlock() }; return Set(storage.keys) }
    }

    /// Answers every claim POST with a fixed Access URL. Sync isn't exercised
    /// here (SyncTests covers it), so GET is never reached.
    private struct Net: NetworkClient {
        static let accessURL = "https://user:pass@bridge.test/simplefin"
        func get(url: URL, basicAuth: BasicAuth?) async throws -> Data { throw TTMError.network("offline") }
        func postJSON(url: URL, body: Data, bearer: String?) async throws -> Data { Data(Self.accessURL.utf8) }
    }

    private static let token = Data("https://bridge.test/claim/abc".utf8).base64EncodedString()

    private var root: URL!
    private var secrets: Secrets!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttm-profile-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        secrets = Secrets()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func core() throws -> LocalCore {
        try LocalCore(profilesRoot: root, secrets: secrets, network: Net(), clock: C())
    }

    private func addAccount(_ store: Store, connectionId: String) throws {
        try store.saveAccount(AccountRecord(id: "a-\(connectionId)", connectionId: connectionId,
            sfinAccountId: "sa", name: "Checking", nickname: nil, currency: "USD", accountClass: "liquid",
            subclass: nil, aprBps: nil, balanceCents: 100, availableCents: nil, balanceDate: 1,
            archived: false, createdAt: 1))
    }

    // MARK: Layout & legacy adoption

    func testFreshRootStartsWithOneActiveProfile() async throws {
        let core = try core()
        let profiles = try await core.profiles()
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?.name, ProfileManager.legacyProfileName)
        XCTAssertEqual(profiles.first?.kind, .real)
        XCTAssertEqual(profiles.first?.isActive, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("profiles.json").path))
    }

    func testPreProfilesStoreIsAdoptedOnceWithItsData() async throws {
        // A store laid out the way the app did before profiles existed.
        let legacyPath = root.appendingPathComponent("ttm.db").path
        let legacy = try Database(path: legacyPath)
        try DefaultData.seedIfEmpty(Store(legacy), now: 1)
        try Store(legacy).saveConnection(ConnectionRecord(id: "c", name: "Bank", keychainRef: "conn-old",
            sfinOrg: nil, status: "ok", lastError: nil, lastSyncedAt: nil, createdAt: 1))
        try legacy.close()
        try Data("undo".utf8).write(to: URL(fileURLWithPath: legacyPath + BackupManager.preRestoreSuffix))

        let first = try core()
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyPath), "legacy store left behind")
        let conns = try await first.connections()
        XCTAssertEqual(conns.map(\.name), ["Bank"], "adopted profile lost its data")
        let undo = await first.canUndoRestore()
        XCTAssertTrue(undo, "the undo copy didn't travel with the store")

        // Idempotent: a second launch adopts nothing new.
        let again = try core()
        let count = try await again.profiles().count
        XCTAssertEqual(count, 1)
    }

    // MARK: Switching

    func testSwitchingIsolatesDataAndSurvivesRelaunch() async throws {
        let core = try core()
        let real = try await core.activeProfile()
        try await core.claimSetupToken(Self.token)

        let test = try await core.createProfile(name: "  Sandbox  ", kind: .test)
        XCTAssertEqual(test.name, "Sandbox", "name not trimmed")
        XCTAssertFalse(test.isActive, "create must not switch")

        try await core.switchProfile(id: test.id)
        var conns = try await core.connections()
        XCTAssertTrue(conns.isEmpty, "a new profile inherited another's connection")
        try await core.loadSampleData()
        let sampleAccounts = try await core.accounts().count
        XCTAssertGreaterThan(sampleAccounts, 0)

        try await core.switchProfile(id: real.id)
        conns = try await core.connections()
        XCTAssertEqual(conns.count, 1)
        XCTAssertEqual(conns.first?.state, .connected, "switching back lost the Keychain link")
        let realAccounts = try await core.accounts().count
        XCTAssertEqual(realAccounts, 0, "sample data leaked across profiles")

        // The active profile is remembered across launches.
        try await core.switchProfile(id: test.id)
        let relaunched = try self.core()
        let active = try await relaunched.activeProfile()
        XCTAssertEqual(active.id, test.id)
        let accounts = try await relaunched.accounts().count
        XCTAssertEqual(accounts, sampleAccounts)
    }

    func testSwitchToUnknownProfileChangesNothing() async throws {
        let core = try core()
        let before = try await core.activeProfile()
        do {
            try await core.switchProfile(id: "nope")
            XCTFail("switched to a profile that doesn't exist")
        } catch let error as ProfileError {
            XCTAssertEqual(error, .notFound)
        }
        let after = try await core.activeProfile()
        XCTAssertEqual(after.id, before.id)
        _ = try await core.categories()   // store still open and usable
    }

    func testRenameKindAndNameValidation() async throws {
        let core = try core()
        let p = try await core.createProfile(name: "Scratch", kind: .real)
        try await core.renameProfile(id: p.id, name: "Rules lab")
        try await core.setProfileKind(id: p.id, kind: .test)
        let renamed = try await core.profiles().first { $0.id == p.id }
        XCTAssertEqual(renamed?.name, "Rules lab")
        XCTAssertEqual(renamed?.kind, .test)

        do {
            _ = try await core.createProfile(name: "   ", kind: .test)
            XCTFail("accepted an empty name")
        } catch let error as ProfileError { XCTAssertEqual(error, .emptyName) }
    }

    // MARK: Delete

    func testDeleteGuardsAndRemovesFolder() async throws {
        let core = try core()
        let only = try await core.activeProfile()
        do { try await core.deleteProfile(id: only.id); XCTFail("deleted the active profile") }
        catch let error as ProfileError { XCTAssertEqual(error, .cannotDeleteActive) }

        let other = try await core.createProfile(name: "Other", kind: .test)
        try await core.switchProfile(id: other.id)
        try await core.switchProfile(id: only.id)
        let folder = root.appendingPathComponent("profiles/\(other.id)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))

        try await core.deleteProfile(id: other.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "store folder left behind")
        let remaining = try await core.profiles().map(\.id)
        XCTAssertEqual(remaining, [only.id])
    }

    // MARK: Import (load a file as a profile)

    func testImportCopiesDataAndGivesTheProfileItsOwnSecrets() async throws {
        let core = try core()
        try await core.claimSetupToken(Self.token)
        let original = try await core.activeProfile()
        let originalRef = try XCTUnwrap(core.store.allConnections().first?.keychainRef)
        let backup = try await core.exportBackup()
        defer { try? FileManager.default.removeItem(at: backup) }

        let imported = try await core.importProfile(from: backup, name: "Copy", kind: .test)
        XCTAssertFalse(imported.isActive, "import must not switch")
        try await core.switchProfile(id: imported.id)

        let conns = try await core.connections()
        XCTAssertEqual(conns.count, 1)
        XCTAssertEqual(conns.first?.state, .connected, "same-device import should keep a working connection")
        let importedRef = try XCTUnwrap(core.store.allConnections().first?.keychainRef)
        XCTAssertNotEqual(importedRef, originalRef, "imported profile shares a Keychain item")
        XCTAssertEqual(try secrets.read(ref: importedRef), Net.accessURL)

        // Deleting the copy takes its own secret and leaves the original's alone.
        try await core.switchProfile(id: original.id)
        try await core.deleteProfile(id: imported.id)
        XCTAssertNil(try secrets.read(ref: importedRef), "deleted profile's secret left in the Keychain")
        XCTAssertEqual(try secrets.read(ref: originalRef), Net.accessURL, "deleting a copy broke the original")
        let state = try await core.connections().first?.state
        XCTAssertEqual(state, .connected)
    }

    func testImportFromAnotherDeviceReportsMissingCredential() async throws {
        let core = try core()
        try await core.claimSetupToken(Self.token)
        let backup = try await core.exportBackup()
        defer { try? FileManager.default.removeItem(at: backup) }

        // A different device: same file, empty Keychain.
        let elsewhere = root.appendingPathComponent("other-device", isDirectory: true)
        let otherCore = try LocalCore(profilesRoot: elsewhere, secrets: Secrets(), network: Net(), clock: C())
        let p = try await otherCore.importProfile(from: backup, name: "From laptop", kind: .real)
        try await otherCore.switchProfile(id: p.id)
        let state = try await otherCore.connections().first?.state
        XCTAssertEqual(state, .missingCredential)
        XCTAssertEqual(state?.canReconnect, true)
    }

    func testImportRejectsGarbageAndLeavesNoTrace() async throws {
        let core = try core()
        let junk = root.appendingPathComponent("junk.ttmbackup")
        try Data("not a database".utf8).write(to: junk)
        let foldersBefore = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("profiles").path)

        do {
            _ = try await core.importProfile(from: junk, name: "Junk", kind: .test)
            XCTFail("imported a non-backup")
        } catch is BackupError {}

        let count = try await core.profiles().count
        XCTAssertEqual(count, 1)
        let foldersAfter = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("profiles").path)
        XCTAssertEqual(Set(foldersAfter), Set(foldersBefore), "a failed import left a folder")
    }

    // MARK: Connection visibility (§4.7)

    func testConnectionStates() async throws {
        let core = try core()
        let store = core.store
        try secrets.write("https://u:p@x.test/s", ref: "conn-ok")
        try secrets.write("https://u:p@x.test/s", ref: "conn-403")
        try store.saveConnection(ConnectionRecord(id: "ok", name: "OK", keychainRef: "conn-ok", sfinOrg: "Bank",
            status: "ok", lastError: nil, lastSyncedAt: 5, createdAt: 1))
        try store.saveConnection(ConnectionRecord(id: "403", name: "Expired", keychainRef: "conn-403", sfinOrg: nil,
            status: "needs_auth", lastError: "HTTP 403", lastSyncedAt: nil, createdAt: 2))
        try store.saveConnection(ConnectionRecord(id: "gone", name: "Restored", keychainRef: "conn-missing",
            sfinOrg: nil, status: "ok", lastError: nil, lastSyncedAt: nil, createdAt: 3))
        try addAccount(store, connectionId: "ok")
        try await core.loadSampleData()

        let byId = Dictionary(uniqueKeysWithValues: try await core.connections().map { ($0.id, $0) })
        XCTAssertEqual(byId["ok"]?.state, .connected)
        XCTAssertEqual(byId["ok"]?.accountCount, 1)
        XCTAssertEqual(byId["ok"]?.org, "Bank")
        XCTAssertEqual(byId["403"]?.state, .needsAuth)
        XCTAssertEqual(byId["gone"]?.state, .missingCredential)
        XCTAssertEqual(byId["demo-conn"]?.state, .sample)
        XCTAssertEqual(byId["demo-conn"]?.state.canReconnect, false)
    }

    func testReconnectReusesTheConnectionSoAccountsDontDuplicate() async throws {
        let core = try core()
        let store = core.store
        try store.saveConnection(ConnectionRecord(id: "c1", name: "Restored", keychainRef: "conn-missing",
            sfinOrg: nil, status: "error", lastError: "missing access URL", lastSyncedAt: 10, createdAt: 1))
        try addAccount(store, connectionId: "c1")

        try await core.reconnect(connectionId: "c1", setupToken: Self.token)

        let conns = try await core.connections()
        XCTAssertEqual(conns.map(\.id), ["c1"], "reconnect created a second connection")
        XCTAssertEqual(conns.first?.state, .connected)
        XCTAssertNil(conns.first?.lastError)
        XCTAssertEqual(conns.first?.accountCount, 1)
        XCTAssertEqual(conns.first?.lastSyncedAt, 10, "reconnect reset the sync cursor")
        let ref = try XCTUnwrap(store.allConnections().first?.keychainRef)
        XCTAssertNotEqual(ref, "conn-missing")
        XCTAssertEqual(try secrets.read(ref: ref), Net.accessURL)
    }

    func testDemoTokenNamesTheConnection() async throws {
        let core = try core()
        try await core.claimSetupToken(SimpleFINDemo.setupToken)
        let name = try await core.connections().first?.name
        XCTAssertEqual(name, SimpleFINDemo.connectionName)
    }

    func testSyncSkipsTheSampleConnection() async throws {
        let core = try core()
        try await core.loadSampleData()
        let outcome = try await core.syncNow()
        XCTAssertEqual(outcome.connectionsFailed, 0, "sample connection counted as a failed sync")
        let state = try await core.connections().first?.state
        XCTAssertEqual(state, .sample)
    }

    func testFixedPathStoreHasNoProfiles() async throws {
        let core = try LocalCore(dbPath: root.appendingPathComponent("plain.db").path,
                                 secrets: secrets, network: Net(), clock: C())
        do { _ = try await core.profiles(); XCTFail("fixed-path store reported profiles") }
        catch let error as ProfileError { XCTAssertEqual(error, .unavailable) }
    }

    // MARK: Setup-token parsing

    func testSetupTokenSurvivesCopyPasteDamage() {
        let url = "https://bridge.test/simplefin/claim/abc1234"
        let padded = Data(url.utf8).base64EncodedString()
        XCTAssertTrue(padded.hasSuffix("="), "fixture should exercise padding")
        let expected = URL(string: url)

        XCTAssertEqual(LocalCore.claimURL(fromSetupToken: padded), expected)
        XCTAssertEqual(LocalCore.claimURL(fromSetupToken: "  \(padded)\n"), expected, "surrounding whitespace")
        let wrapped = String(padded.prefix(10)) + "\n" + String(padded.dropFirst(10))
        XCTAssertEqual(LocalCore.claimURL(fromSetupToken: wrapped), expected, "line break inside the token")
        XCTAssertEqual(LocalCore.claimURL(fromSetupToken: padded.replacingOccurrences(of: "=", with: "")),
                       expected, "missing padding")
        XCTAssertEqual(LocalCore.claimURL(fromSetupToken: SimpleFINDemo.setupToken),
                       URL(string: "https://beta-bridge.simplefin.org/simplefin/claim/DEMO"))

        XCTAssertNil(LocalCore.claimURL(fromSetupToken: "hello world"))
        XCTAssertNil(LocalCore.claimURL(fromSetupToken: Data("not a url".utf8).base64EncodedString()))
        XCTAssertNil(LocalCore.claimURL(fromSetupToken: Data("ftp://x.test/claim".utf8).base64EncodedString()))
    }

    func testAlreadyClaimedTokenGetsAPlainMessage() async throws {
        struct Refusing: NetworkClient {
            func get(url: URL, basicAuth: BasicAuth?) async throws -> Data { Data() }
            func postJSON(url: URL, body: Data, bearer: String?) async throws -> Data { throw TTMError.network("HTTP 403") }
        }
        let core = try LocalCore(profilesRoot: root, secrets: secrets, network: Refusing(), clock: C())
        do {
            try await core.claimSetupToken(Self.token)
            XCTFail("claim succeeded against a 403")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("already been used"), "\(error.localizedDescription)")
        }
        let conns = try await core.connections()
        XCTAssertTrue(conns.isEmpty, "a failed claim left a connection behind")
    }
}
