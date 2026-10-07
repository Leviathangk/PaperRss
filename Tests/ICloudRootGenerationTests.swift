@preconcurrency import CloudKit
import Foundation
import GRDB
import XCTest
@testable import PaperRssCore

final class ICloudRootGenerationTests: XCTestCase {
    private let first = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    private let second = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
    private var directories: [URL] = []
    private struct Peer: Sendable {
        let database: LibraryDatabase
        let repository: ICloudRecordRepository
        let url: URL
        var coordinator: ICloudRootCoordinator { .init(repository: repository) }
    }
    override func tearDownWithError() throws {
        for directory in directories { try FileManager.default.removeItem(at: directory) }
    }
    private func peer() throws -> Peer {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RootTests-\(UUID())")
        directories.append(directory)
        let url = directory.appendingPathComponent("library.sqlite")
        let database = try LibraryDatabase(databaseURL: url)
        try database.write {
            try AccountRecord(id: "cloud", type: "iCloud", displayName: "iCloud", createdAt: 1, updatedAt: 1).save($0)
        }
        let repository = ICloudRecordRepository(database: database, accountID: "cloud")
        try repository.activate()
        return .init(database: database, repository: repository, url: url)
    }
    private func pause(_ peer: Peer) throws -> String? {
        try peer.database.read { try String.fetchOne($0, sql: "SELECT pause_reason FROM icloud_sync_scope") }
    }
    private actor Cloud: ICloudRootTransport {
        var root: ICloudCloudRoot?
        var hasDataZones: Bool
        var lookups = 0
        var proposals: [String] = []
        var createFailsAfterSaving = false
        var lookupFailure: (any Error)?
        init(root: ICloudCloudRoot? = nil, hasDataZones: Bool = false) {
            self.root = root; self.hasDataZones = hasDataZones
        }
        func setRoot(_ value: ICloudCloudRoot?) { root = value }
        func failCreateAfterSaving() { createFailsAfterSaving = true }
        func failLookup(_ error: any Error) { lookupFailure = error }
        func lookupRoot() async throws -> ICloudRootLookup {
            lookups += 1
            if let error = lookupFailure { lookupFailure = nil; throw error }
            return root.map(ICloudRootLookup.found) ?? .missing(hasExistingData: hasDataZones)
        }
        func createRoot(proposal: String) async throws -> ICloudCloudRoot {
            proposals.append(proposal)
            if root == nil { root = .init(generation: proposal, phase: .ready) }
            if createFailsAfterSaving {
                createFailsAfterSaving = false
                throw ICloudEngineError.temporarilyUnavailable
            }
            return root!
        }
    }

    func testEmptyLibraryInitializesOnceAndDoesNotAcknowledgeOrChangeLocalIntents() async throws {
        let peer = try peer(), cloud = Cloud()
        let pending = try peer.repository.outgoingRecords()
        let clock = try peer.database.read { try Int64.fetchOne($0, sql: "SELECT logical_clock FROM icloud_sync_scope") }
        let generation = try await peer.coordinator.ensureGeneration(using: cloud)
        XCTAssertNotNil(UUID(uuidString: generation))
        XCTAssertEqual(try peer.repository.boundCloudGeneration(), generation)
        let verified = try await peer.coordinator.ensureGeneration(using: cloud)
        XCTAssertEqual(verified, generation)
        let proposals = await cloud.proposals
        XCTAssertEqual(proposals, [generation])
        XCTAssertEqual(try peer.repository.outgoingRecords(), pending)
        XCTAssertEqual(try peer.database.read { try Int64.fetchOne($0, sql: "SELECT logical_clock FROM icloud_sync_scope") }, clock)
        XCTAssertNil(try pause(peer))
    }

    func testJoiningExistingRootBindsWithoutChangingItOrSendingUserRecords() async throws {
        let peer = try peer(), cloud = Cloud(root: .init(generation: first, phase: .ready), hasDataZones: true)
        let generation = try await peer.coordinator.ensureGeneration(using: cloud)
        XCTAssertEqual(generation, first)
        let proposals = await cloud.proposals
        XCTAssertTrue(proposals.isEmpty)
        XCTAssertEqual(try peer.repository.boundCloudGeneration(), first)
    }

    func testTwoMacsInitializingAtOnceAdoptOneServerWinner() async throws {
        let one = try peer(), two = try peer(), cloud = Cloud()
        let firstCoordinator = one.coordinator, secondCoordinator = two.coordinator
        async let a = firstCoordinator.ensureGeneration(using: cloud)
        async let b = secondCoordinator.ensureGeneration(using: cloud)
        let result = try await (a, b)
        XCTAssertEqual(result.0, result.1)
        XCTAssertEqual(try one.repository.boundCloudGeneration(), result.0)
        XCTAssertEqual(try two.repository.boundCloudGeneration(), result.0)
        XCTAssertNil(try pause(one))
        XCTAssertNil(try pause(two))
    }

    func testAmbiguousCreateSuccessKeepsProposalAndRetryAdoptsSavedRoot() async throws {
        let peer = try peer(), cloud = Cloud()
        await cloud.failCreateAfterSaving()
        do {
            _ = try await peer.coordinator.ensureGeneration(using: cloud)
            XCTFail("Expected temporary failure")
        } catch { XCTAssertEqual(error as? ICloudEngineError, .temporarilyUnavailable) }
        let proposal = try await peer.repository.proposeCloudGeneration()
        let initial = try await peer.repository.rootBinding()
        XCTAssertNil(initial.generation)
        let retried = try await peer.coordinator.ensureGeneration(using: cloud)
        XCTAssertEqual(retried, proposal)
        let proposals = await cloud.proposals
        XCTAssertEqual(proposals, [proposal])
        XCTAssertNil(try pause(peer))
    }

    func testProposalAndBindingSurviveDatabaseReopen() async throws {
        let path: URL
        let proposal: String
        do {
            let peer = try peer()
            path = peer.url
            proposal = try await peer.repository.proposeCloudGeneration()
        }
        let reopened = try LibraryDatabase(databaseURL: path)
        let repository = ICloudRecordRepository(database: reopened, accountID: "cloud")
        let existing = try await repository.proposeCloudGeneration()
        XCTAssertEqual(existing, proposal)
        try await repository.acceptCloudRoot(.init(generation: proposal, phase: .ready))
        XCTAssertEqual(try repository.boundCloudGeneration(), proposal)
    }

    func testGenerationChangeCommitsPauseAndPreservesJournalAndBoundEpoch() async throws {
        let peer = try peer(), cloud = Cloud(root: .init(generation: first, phase: .ready))
        _ = try await peer.coordinator.ensureGeneration(using: cloud)
        let before = try peer.repository.outgoingRecords()
        await cloud.setRoot(.init(generation: second, phase: .ready))
        do {
            _ = try await peer.coordinator.ensureGeneration(using: cloud)
            XCTFail("Expected quarantine")
        } catch { XCTAssertEqual(error as? ICloudRootError, .generationChanged) }
        XCTAssertEqual(try pause(peer), "cloudGenerationChanged")
        XCTAssertEqual(try peer.database.read { try String.fetchOne($0, sql: "SELECT cloud_generation FROM icloud_sync_scope") }, first)
        let pendingCount = try peer.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM icloud_records WHERE is_pending = 1") }
        XCTAssertEqual(pendingCount, before.count)
    }

    func testMissingBoundRootCannotBeRecreatedAndResettingRootPauses() async throws {
        let peer = try peer(), cloud = Cloud(root: .init(generation: first, phase: .ready))
        _ = try await peer.coordinator.ensureGeneration(using: cloud)
        await cloud.setRoot(nil)
        do {
            _ = try await peer.coordinator.ensureGeneration(using: cloud)
            XCTFail("Expected missing root")
        } catch { XCTAssertEqual(error as? ICloudRootError, .rootMissing) }
        let proposals = await cloud.proposals
        XCTAssertTrue(proposals.isEmpty)
        XCTAssertEqual(try pause(peer), "cloudRootMissing")
        let fresh = try self.peer()
        do {
            _ = try await fresh.coordinator.ensureGeneration(using: Cloud(root: .init(generation: second, phase: .resetting)))
            XCTFail("Expected reset hold")
        } catch { XCTAssertEqual(error as? ICloudRootError, .resetInProgress) }
        XCTAssertEqual(try pause(fresh), "cloudResetInProgress")
    }

    func testLegacyZonesOrCheckpointRequireReviewWithoutCreatingRoot() async throws {
        let empty = try peer(), legacyCloud = Cloud(hasDataZones: true)
        do {
            _ = try await empty.coordinator.ensureGeneration(using: legacyCloud)
            XCTFail("Expected legacy hold")
        } catch { XCTAssertEqual(error as? ICloudRootError, .legacyCloudRequiresReview) }
        let proposals = await legacyCloud.proposals
        XCTAssertTrue(proposals.isEmpty)
        XCTAssertEqual(try pause(empty), "legacyCloudRoot")
        let saved = try peer(), remote = Cloud(root: .init(generation: first, phase: .ready))
        try saved.repository.persistEngineState(Data([7, 8]))
        do {
            _ = try await saved.coordinator.ensureGeneration(using: remote)
            XCTFail("Existing checkpoint cannot be rebound automatically")
        } catch { XCTAssertEqual(error as? ICloudRootError, .legacyCloudRequiresReview) }
        let lookups = await remote.lookups
        XCTAssertEqual(lookups, 0)
        XCTAssertEqual(try saved.database.read { try Data.fetchOne($0, sql: "SELECT engine_state FROM icloud_sync_scope") }, Data([7, 8]))
    }

    func testConfirmedLegacyWireCacheAlsoRequiresReview() async throws {
        let peer = try peer()
        for value in try peer.repository.outgoingRecords() {
            try peer.repository.confirm(value, server: .init(envelope: value.envelope, systemFields: nil))
        }
        let binding = try await peer.repository.rootBinding()
        XCTAssertTrue(binding.hasPriorCloudState)
        do {
            _ = try await peer.coordinator.ensureGeneration(using: Cloud())
            XCTFail("Server-confirmed legacy data must not be silently reassigned")
        } catch { XCTAssertEqual(error as? ICloudRootError, .legacyCloudRequiresReview) }
    }

    func testTransientLookupFailureRetainsDataAndDoesNotInventRootOrPause() async throws {
        let peer = try peer(), cloud = Cloud(root: .init(generation: first, phase: .ready))
        await cloud.failLookup(ICloudEngineError.temporarilyUnavailable)
        do {
            _ = try await peer.coordinator.ensureGeneration(using: cloud)
            XCTFail("Expected failure")
        } catch { XCTAssertEqual(error as? ICloudEngineError, .temporarilyUnavailable) }
        XCTAssertNil(try pause(peer))
        let proposals = await cloud.proposals
        XCTAssertTrue(proposals.isEmpty)
        let recovered = try await peer.coordinator.ensureGeneration(using: cloud)
        XCTAssertEqual(recovered, first)
    }

    func testInvalidRootAndDisabledAccountCannotAdvanceBinding() async throws {
        let peer = try peer(), invalid = Cloud()
        await invalid.failLookup(ICloudRootError.unsupportedVersion)
        do {
            _ = try await peer.coordinator.ensureGeneration(using: invalid)
            XCTFail("Expected unsupported root")
        } catch { XCTAssertEqual(error as? ICloudRootError, .unsupportedVersion) }
        XCTAssertEqual(try pause(peer), "invalidCloudRoot")
        let disabled = try self.peer()
        try disabled.database.write { try $0.execute(sql: "UPDATE accounts SET is_enabled = 0 WHERE id = 'cloud'") }
        let remote = Cloud()
        do {
            _ = try await disabled.coordinator.ensureGeneration(using: remote)
            XCTFail("Disabled account must not query or mutate cloud")
        } catch { XCTAssertEqual(error as? ICloudRecordError, .unavailableScope) }
        let lookups = await remote.lookups
        XCTAssertEqual(lookups, 0)
    }

    func testCorruptLocalProposalPausesBeforeAnyCloudMutation() async throws {
        let peer = try peer(), cloud = Cloud()
        try peer.database.write {
            try $0.execute(sql: "UPDATE icloud_sync_scope SET cloud_generation_proposal = 'invalid-proposal'")
        }
        do {
            _ = try await peer.coordinator.ensureGeneration(using: cloud)
            XCTFail("Expected malformed proposal")
        } catch { XCTAssertEqual(error as? ICloudRootError, .malformedRoot) }
        XCTAssertEqual(try pause(peer), "invalidCloudRoot")
        let proposals = await cloud.proposals
        XCTAssertTrue(proposals.isEmpty)
    }

    private actor Session {
        var active = true
        func stop() { active = false }
    }
    private actor BlockedLookup: ICloudRootTransport {
        var gate: CheckedContinuation<ICloudRootLookup, Never>?
        var waiters: [CheckedContinuation<Void, Never>] = []
        func waitUntilStarted() async {
            if gate != nil { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release(_ root: ICloudCloudRoot) { gate?.resume(returning: .found(root)); gate = nil }
        func lookupRoot() async throws -> ICloudRootLookup {
            await withCheckedContinuation { continuation in
                gate = continuation
                for waiter in waiters { waiter.resume() }
                waiters.removeAll()
            }
        }
        func createRoot(proposal: String) async throws -> ICloudCloudRoot { throw ICloudRecordError.persistenceFailed }
    }

    func testStoppedSessionRejectsLateRootWithoutPausingOrBindingAnotherSession() async throws {
        let peer = try peer(), remote = BlockedLookup(), session = Session()
        let coordinator = peer.coordinator
        let work = Task { try await coordinator.ensureGeneration(using: remote, isCurrent: { await session.active }) }
        await remote.waitUntilStarted()
        await session.stop()
        await remote.release(.init(generation: first, phase: .ready))
        do {
            _ = try await work.value
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        let binding = try await peer.repository.rootBinding()
        XCTAssertNil(binding.generation)
        XCTAssertNil(try pause(peer))
    }

    func testOldExpectedEpochCannotPauseAReboundScope() async throws {
        let peer = try peer()
        try await peer.repository.acceptCloudRoot(.init(generation: second, phase: .ready))
        do {
            try await peer.repository.acceptCloudRoot(.init(generation: first, phase: .ready), expectedGeneration: first)
            XCTFail("Expected stale callback rejection")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(try pause(peer))
        XCTAssertEqual(try peer.repository.boundCloudGeneration(), second)
    }

    private func envelope() throws -> ICloudRecordEnvelope {
        let url = URL(string: "https://example.com/rss")!
        let name = try XCTUnwrap(ICloudSyncIdentity.articleRecordName(feedURL: url, sourceItemID: "urn:opaque:article"))
        return try .init(kind: .read, recordName: "read-v1:" + name.dropFirst("article-v1:".count),
            feedURL: url.absoluteString, sourceItemID: "urn:opaque:article",
            fields: ["value": .init(value: .flag(true), version: .init(counter: 5, deviceID: first))])
    }

    func testGenerationNamesSeparateCloudIDsWhileKeepingOpaqueWireIdentity() throws {
        let wire = try envelope()
        let a = try ICloudRecordCodec.encode(wire, systemFields: nil, generation: first)
        let b = try ICloudRecordCodec.encode(wire, systemFields: nil, generation: second)
        XCTAssertNotEqual(a.recordID, b.recordID)
        XCTAssertEqual(try ICloudRecordCodec.received(a, generation: first).envelope, wire)
        XCTAssertEqual(try ICloudGenerationIdentity.classify(a.recordID.recordName, generation: first), .current(wire.recordName))
        XCTAssertEqual(try ICloudGenerationIdentity.classify(a.recordID.recordName, generation: second), .otherGeneration)
        XCTAssertThrowsError(try ICloudRecordCodec.received(a, generation: second))
        XCTAssertThrowsError(try ICloudRecordCodec.encode(wire, systemFields: ICloudRecordCodec.systemFields(a), generation: second))
        let legacy = try ICloudRecordCodec.encode(wire, systemFields: nil)
        XCTAssertEqual(try ICloudGenerationIdentity.classify(legacy.recordID.recordName, generation: first), .legacy)
        XCTAssertThrowsError(try ICloudRecordCodec.received(legacy, generation: first))
    }

    func testMalformedNamespaceCannotMasqueradeAsCurrentOrForeignEpoch() throws {
        for name in ["epoch-v1:bad:read-v1:abc", "epoch-v1:\(first):", "epoch-v1:\(first.lowercased()):read-v1:abc"] {
            XCTAssertThrowsError(try ICloudGenerationIdentity.classify(name, generation: first))
        }
    }

    func testRootCodecWhitelistAndSchemaRejectUnknownFieldsBooleanVersionsAndInvalidPhases() throws {
        let root = ICloudCloudRoot(generation: first, phase: .ready)
        let record = try ICloudCloudRootCodec.encode(root)
        XCTAssertEqual(try ICloudCloudRootCodec.decode(record), root)
        record["schemaVersion"] = true as NSNumber
        XCTAssertThrowsError(try ICloudCloudRootCodec.decode(record))
        record["schemaVersion"] = 4 as NSNumber
        XCTAssertThrowsError(try ICloudCloudRootCodec.decode(record)) { XCTAssertEqual($0 as? ICloudRootError, .unsupportedVersion) }
        record["schemaVersion"] = ICloudCloudRootCodec.schemaVersion as NSNumber
        record["phase"] = "unknown" as NSString
        XCTAssertThrowsError(try ICloudCloudRootCodec.decode(record))
        record["phase"] = "ready" as NSString
        record["unexpected"] = "not-for-upload" as NSString
        XCTAssertThrowsError(try ICloudCloudRootCodec.decode(record))
    }

    func testAtomicPartialConflictSelectsOnlyRootServerWinnerAndDoesNotHideOtherErrors() throws {
        let server = try ICloudCloudRootCodec.encode(.init(generation: second, phase: .ready))
        let conflict = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server])
        let partial = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [ICloudCloudRootCodec.recordID: conflict]])
        XCTAssertEqual(try ICloudRootCloudKitTransport.conflictWinner(partial)?.generation, second)
        XCTAssertEqual(try ICloudRootCloudKitTransport.conflictWinner(conflict)?.generation, second)
        XCTAssertNil(try ICloudRootCloudKitTransport.conflictWinner(CKError(.networkFailure)))
        let quota = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [ICloudCloudRootCodec.recordID: CKError(.quotaExceeded)]])
        XCTAssertNil(try ICloudRootCloudKitTransport.conflictWinner(quota))
    }

    func testRootFailuresHaveSpecificSafeMessagesWithoutPrivateValues() {
        let errors: [ICloudRootError] = [.generationChanged, .rootMissing, .resetInProgress,
            .legacyCloudRequiresReview, .malformedRoot, .unsupportedVersion]
        let messages = errors.map { ICloudSyncFailure.message(for: $0) }
        XCTAssertEqual(Set(messages).count, 5)
        for message in messages {
            XCTAssertFalse(message.contains(first))
            XCTAssertFalse(message.contains("https://"))
            XCTAssertFalse(message.contains("CKRecord"))
        }
    }

    func testV16UpgradePreservesHistoryAndCheckpointWithoutBindingAnyRoot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RootV16Tests-\(UUID())")
        directories.append(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: directory.appendingPathComponent("library.sqlite").path)
        try DatabaseMigrations.migrator.migrate(pool, upTo: "v16-icloud-article-content")
        let feed = UUID().uuidString
        try pool.write { db in
            try AccountRecord(id: "local", type: "local", displayName: "Local", createdAt: 1, updatedAt: 1).save(db)
            try AccountRecord(id: "cloud", type: "iCloud", displayName: "iCloud", createdAt: 1, updatedAt: 1).save(db)
            try FeedRecord(id: feed, accountID: "local", title: "History", feedURL: "https://example.com/rss", updatedAt: 1).save(db)
            try ItemRecord(id: "old", accountID: "local", externalID: "old", feedID: feed, createdAt: 1, updatedAt: 1, sourceItemID: "opaque-old").save(db)
            try ArticleRecord(itemID: "old", title: "Keep", contentHTML: "<p>Keep history</p>").save(db)
            try ArticleStateRecord(itemID: "old", isRead: true, isStarred: true, dateArrived: 1, updatedAt: 1).save(db)
            try db.execute(sql: "INSERT INTO icloud_sync_scope (account_id, capture_enabled, engine_state, initialized_zones) VALUES ('cloud', 1, ?, 3)",
                           arguments: [Data([3, 4])])
        }
        try DatabaseMigrations.migrator.migrate(pool)
        try pool.read { db in
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT cloud_generation FROM icloud_sync_scope"))
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT cloud_generation_proposal FROM icloud_sync_scope"))
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT pause_reason FROM icloud_sync_scope"))
            XCTAssertEqual(try Data.fetchOne(db, sql: "SELECT engine_state FROM icloud_sync_scope"), Data([3, 4]))
            XCTAssertEqual(try ArticleRecord.fetchOne(db, key: "old")?.contentHTML, "<p>Keep history</p>")
            XCTAssertEqual(try ItemRecord.fetchOne(db, key: "old")?.sourceItemID, "opaque-old")
            XCTAssertTrue(try ArticleStateRecord.fetchOne(db, key: "old")?.isRead == true)
            XCTAssertTrue(try ArticleStateRecord.fetchOne(db, key: "old")?.isStarred == true)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM icloud_sync_changes"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM icloud_content_changes"), 0)
            XCTAssertEqual(try String.fetchAll(db, sql: "PRAGMA integrity_check"), ["ok"])
        }
    }
}
