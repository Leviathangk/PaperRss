import CloudKit
import Foundation
import GRDB
import XCTest
@testable import PaperRssCore

private actor ArchiveFlowGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}
private struct ArchiveFlowCloud: ICloudArchiveCloudReading {
    var fingerprint = "new-user"
    var generation = "00000000-0000-0000-0000-000000000002"
    var isEmpty = false
    func observe() async throws -> ICloudArchiveCloudObservation {
        if isEmpty { return .init(fingerprint: fingerprint, root: .missing, zones: [], legacySnapshotExists: false) }
        return .init(fingerprint: fingerprint, root: .found(.init(generation: generation, phase: .ready), changeTag: "tag"),
              zones: try ICloudRecordZone.allCases.map { try ICloudGenerationZone.id($0, generation: generation) })
    }
}
private actor ArchiveFlowSync: ICloudAccountSyncing {
    let database: LibraryDatabase
    var events: [String] = []
    var prepareGate: ArchiveFlowGate?
    var executeGate: ArchiveFlowGate?
    var refreshGate: ArchiveFlowGate?
    var committedGate: ArchiveFlowGate?
    var failFetch = false
    var cloud = ArchiveFlowCloud()
    var approvedPlan: ICloudArchiveRecoveryPlan?
    init(database: LibraryDatabase) { self.database = database }
    func fetchChanges() async throws {
        events.append("fetch")
        if let gate = refreshGate { await gate.wait() }
        if failFetch { throw NSError(domain: "private-user", code: 1, userInfo: [NSLocalizedDescriptionKey: "private-rss-link-token"]) }
    }
    func sendChanges() async throws { events.append("send") }
    func stop() async { events.append("stop"); approvedPlan = nil }
    func prepareArchiveRecovery() async throws -> ICloudArchiveRecoveryPlan {
        events.append("prepare")
        if let gate = prepareGate { await gate.wait() }
        try Task.checkCancellation()
        let plan = try await coordinator().prepare()
        approvedPlan = plan
        return plan
    }
    func executeArchiveRecovery(_ plan: ICloudArchiveRecoveryPlan, initializeEmptyCloudConfirmed: Bool) async throws -> AccountRecord {
        events.append("execute")
        if let gate = executeGate { await gate.wait() }
        try Task.checkCancellation()
        guard approvedPlan?.id == plan.id else { throw ICloudArchiveRecoveryError.staleReview }
        approvedPlan = nil
        let account = try await coordinator().execute(plan, initializeEmptyCloudConfirmed: initializeEmptyCloudConfirmed)
        if let gate = committedGate { await gate.wait() }
        return account
    }
    func discardArchiveRecovery(planID: UUID) async {
        if approvedPlan?.id == planID { approvedPlan = nil }
        events.append("discard")
    }
    private func coordinator() throws -> ICloudArchiveRecoveryCoordinator {
        let id = try database.read { try String.fetchOne($0, sql: "SELECT id FROM accounts WHERE type='iCloud' AND is_archived=0")! }
        return .init(database: database, accountID: id, transport: cloud)
    }
    func clearEvents() { events = [] }
    func snapshot() -> [String] { events }
    func holdPrepare(_ gate: ArchiveFlowGate) { prepareGate = gate }
    func holdExecute(_ gate: ArchiveFlowGate) { executeGate = gate }
    func holdRefresh(_ gate: ArchiveFlowGate) { refreshGate = gate }
    func holdCommitted(_ gate: ArchiveFlowGate) { committedGate = gate }
    func failRestoration() { failFetch = true }
    func changeCloud() { cloud.generation = UUID().uuidString }
    func useEmptyCloud() { cloud.isEmpty = true }
}

@MainActor
final class ICloudArchiveRecoveryFlowTests: XCTestCase {
    private var store: AppStore!
    private var oldSync: ArchiveFlowSync!
    private var newSync: ArchiveFlowSync!
    private var oldAccount: AccountRecord!
    override func setUp() async throws {
        store = AppStore(testDatabase: .empty)
        oldSync = ArchiveFlowSync(database: store.libraryDatabase); newSync = ArchiveFlowSync(database: store.libraryDatabase)
        oldAccount = try await store.createICloudAccount(fingerprint: "old-user", sync: oldSync)
        try store.libraryDatabase.write { db in
            try db.execute(sql: "UPDATE icloud_sync_scope SET pause_reason='accountChanged', cloud_generation=?, initialized_zones=3, engine_state=? WHERE account_id=?",
                arguments: ["00000000-0000-0000-0000-000000000001", Data([3, 5, 7]), oldAccount.id])
            try FeedRecord(id: UUID().uuidString, accountID: oldAccount.id, title: "Old feed", feedURL: "https://archive.example/rss", updatedAt: 1).insert(db)
        }
        store.reloadState(); await Task.yield(); await oldSync.clearEvents()
    }
    override func tearDown() async throws {
        for provider in await store.syncCoordinator.allProviders() {
            if let provider = provider as? ICloudAccountProvider { await provider.stop() }
        }
        let directory = URL(fileURLWithPath: store.libraryDatabase.databasePath).deletingLastPathComponent()
        oldAccount = nil; oldSync = nil; newSync = nil; store = nil
        try FileManager.default.removeItem(at: directory)
    }
    private func prepare() async throws -> ICloudArchiveRecoveryReview {
        try await store.prepareICloudArchiveRecoveryAfterEntitlementCheck(accountID: oldAccount.id, connectionConfirmed: true)
    }
    private func execute(_ review: ICloudArchiveRecoveryReview) async throws -> ICloudArchiveRecoveryResult {
        try await store.executeICloudArchiveRecoveryAfterEntitlementCheck(reviewID: review.id, archiveConfirmed: true, newSync: newSync)
    }
    private func rows() throws -> [Row] {
        try store.libraryDatabase.read { db in
            var result: [Row] = []
            for table in ["accounts", "feeds", "items", "articles", "article_states", "icloud_sync_scope", "icloud_sync_changes"] {
                result += try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY rowid")
            }
            return result
        }
    }
    private func wait(_ gate: ArchiveFlowGate) async throws {
        for _ in 0..<100 { if await gate.entered { return }; try await Task.sleep(for: .milliseconds(20)) }
        XCTFail("Expected gate entry")
    }
    func testLocalReviewNeedsNoEntitlementOrNetworkAndPreservesData() async throws {
        let before = try rows()
        let review = try await store.iCloudArchiveLocalReview(accountID: oldAccount.id)
        XCTAssertEqual(review.feeds, 1)
        XCTAssertEqual(try rows(), before)
        let events = await oldSync.snapshot(); XCTAssertTrue(events.isEmpty)
    }
    func testConnectionAndArchiveConfirmationAreRequiredIndependently() async throws {
        let before = try rows()
        do { _ = try await store.prepareICloudArchiveRecoveryAfterEntitlementCheck(accountID: oldAccount.id, connectionConfirmed: false); XCTFail("Connection confirmation required") }
        catch ICloudArchiveRecoveryError.connectionConfirmationRequired {}
        let review = try await prepare()
        XCTAssertEqual(try rows(), before)
        do { _ = try await store.executeICloudArchiveRecoveryAfterEntitlementCheck(reviewID: review.id, archiveConfirmed: false, newSync: newSync); XCTFail("Archive confirmation required") }
        catch ICloudArchiveRecoveryError.archiveConfirmationRequired {}
        XCTAssertEqual(try rows(), before)
        _ = try await execute(review)
    }
    func testEmptyCloudRequiresAnAdditionalConsentWithoutConsumingTheReviewedPlan() async throws {
        await oldSync.useEmptyCloud()
        let before = try rows(), review = try await prepare()
        XCTAssertTrue(review.needsCloudInitialization); XCTAssertEqual(try rows(), before)
        do { _ = try await execute(review); XCTFail("Archive confirmation alone is insufficient for empty cloud initialization") }
        catch ICloudArchiveRecoveryError.cloudInitializationConfirmationRequired {}
        let provider = await store.syncCoordinator.provider(for: oldAccount.id) as! ICloudAccountProvider
        do { _ = try await provider.executeArchiveRecovery(reviewID: review.id); XCTFail("Provider must also retain the unconfirmed plan") }
        catch ICloudArchiveRecoveryError.cloudInitializationConfirmationRequired {}
        XCTAssertEqual(try rows(), before)
        let rejectedEvents = await oldSync.snapshot(); XCTAssertEqual(rejectedEvents, ["stop", "prepare"])
        let result = try await store.executeICloudArchiveRecoveryAfterEntitlementCheck(reviewID: review.id,
            archiveConfirmed: true, initializeEmptyCloudConfirmed: true, newSync: newSync)
        XCTAssertEqual(store.activeAccountID, result.newAccountID)
        XCTAssertTrue(store.accounts.first(where: { $0.id == oldAccount.id })!.isArchived)
        try store.libraryDatabase.read { db in
            let scope = try Row.fetchOne(db, sql: "SELECT * FROM icloud_sync_scope WHERE account_id=?", arguments: [result.newAccountID])!
            XCTAssertEqual(scope["cloud_generation"] as DatabaseValue, .null)
            XCTAssertEqual(scope["initialized_zones"] as Int, 0)
            let proposal: String = scope["cloud_generation_proposal"]; XCTAssertNotNil(UUID(uuidString: proposal))
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM feeds WHERE account_id=?", arguments: [result.newAccountID]), 0)
        }
        let events = await newSync.snapshot(); XCTAssertTrue(events.contains("fetch"))
    }
    func testEmptyCloudBootstrapFailureReturnsCommittedArchiveWithASafeWarning() async throws {
        await oldSync.useEmptyCloud(); await newSync.failRestoration()
        let review = try await prepare()
        let result = try await store.executeICloudArchiveRecoveryAfterEntitlementCheck(reviewID: review.id,
            archiveConfirmed: true, initializeEmptyCloudConfirmed: true, newSync: newSync)
        XCTAssertTrue(store.accounts.first(where: { $0.id == oldAccount.id })!.isArchived)
        XCTAssertEqual(store.activeAccountID, result.newAccountID)
        let warning = try XCTUnwrap(result.syncWarning)
        XCTAssertFalse(warning.contains("private-user")); XCTAssertFalse(warning.contains("private-rss-link-token"))
        XCTAssertNotNil(try store.libraryDatabase.read { try String.fetchOne($0, sql: "SELECT cloud_generation_proposal FROM icloud_sync_scope WHERE account_id=?", arguments: [result.newAccountID]) })
    }
    func testPrepareStopsOldWorkBeforeMetadataAndNeverCopiesOrSends() async throws {
        let before = try rows(); let review = try await prepare()
        XCTAssertEqual(review.counts.feeds, 1)
        let events = await oldSync.snapshot(); XCTAssertEqual(events, ["stop", "prepare"])
        XCTAssertEqual(try rows(), before)
        let provider = await store.syncCoordinator.provider(for: oldAccount.id) as! ICloudAccountProvider
        do { _ = try await provider.refresh(reason: .manual); XCTFail("Old refresh must wait") } catch ICloudArchiveRecoveryError.operationInProgress {}
        do { try await provider.pushPendingArticleStates(); XCTFail("Old send must wait") } catch ICloudArchiveRecoveryError.operationInProgress {}
        do { _ = try await provider.addFolder(name: "During review"); XCTFail("Old edit must wait") } catch ICloudArchiveRecoveryError.operationInProgress {}
        XCTAssertEqual(try rows(), before)
    }
    func testCommitProjectsArchiveAndNewAccountBeforeNormalRestoration() async throws {
        let review = try await prepare(), result = try await execute(review)
        XCTAssertNil(result.syncWarning); XCTAssertNotEqual(result.newAccountID, oldAccount.id)
        XCTAssertEqual(store.activeAccountID, result.newAccountID)
        XCTAssertEqual(store.accounts.first { $0.id == oldAccount.id }?.isArchived, true)
        XCTAssertEqual(store.accounts.first { $0.id == oldAccount.id }?.isEnabled, false)
        XCTAssertTrue(store.feeds(for: result.newAccountID).isEmpty)
        let old = await store.syncCoordinator.provider(for: oldAccount.id); XCTAssertNil(old)
        let fresh = await store.syncCoordinator.provider(for: result.newAccountID); XCTAssertNotNil(fresh)
        let events = await oldSync.snapshot(); XCTAssertEqual(events.filter { $0 == "execute" }.count, 1)
        XCTAssertFalse(events.contains("fetch")); XCTAssertFalse(events.contains("send"))
        let newEvents = await newSync.snapshot(); XCTAssertEqual(newEvents, ["fetch", "send"])
    }
    func testCommittedArchiveRemainsSuccessfulWhenNewCloudRestorationFails() async throws {
        await newSync.failRestoration()
        let result = try await execute(prepare())
        XCTAssertNotNil(result.syncWarning)
        XCTAssertFalse(result.syncWarning!.contains("private-rss-link-token"))
        XCTAssertFalse(result.syncWarning!.contains("private-user"))
        XCTAssertEqual(store.accounts.first { $0.id == oldAccount.id }?.isArchived, true)
        XCTAssertNotNil(store.accounts.first { $0.id == result.newAccountID })
    }
    func testReviewCannotBeReusedOrTransferred() async throws {
        let review = try await prepare()
        do { _ = try await store.executeICloudArchiveRecoveryAfterEntitlementCheck(reviewID: UUID(), archiveConfirmed: true, newSync: newSync); XCTFail("Wrong review") }
        catch ICloudArchiveRecoveryError.staleReview {}
        _ = try await execute(review)
        let after = try rows()
        do { _ = try await execute(review); XCTFail("Consumed review") } catch ICloudArchiveRecoveryError.staleReview {}
        XCTAssertEqual(try rows(), after)
    }
    func testDiscardInvalidatesApprovalWithoutChangingLibrary() async throws {
        let before = try rows(), review = try await prepare()
        await store.discardICloudArchiveRecoveryReview(id: review.id)
        do { _ = try await execute(review); XCTFail("Discarded review") } catch ICloudArchiveRecoveryError.staleReview {}
        XCTAssertEqual(try rows(), before)
        let again = try await prepare(); XCTAssertNotEqual(again.id, review.id)
    }
    func testChangedTargetRejectsExecutionAndPreservesOldLibrary() async throws {
        let review = try await prepare(), before = try rows()
        await oldSync.changeCloud()
        do { _ = try await execute(review); XCTFail("Changed target") } catch ICloudArchiveRecoveryError.staleReview {}
        XCTAssertEqual(try rows(), before)
    }
    func testConcurrentPrepareAndResumeCannotBypassRecoveryLease() async throws {
        let gate = ArchiveFlowGate(); await oldSync.holdPrepare(gate)
        let operation = Task { try await prepare() }; try await wait(gate)
        do { _ = try await prepare(); XCTFail("Concurrent prepare") } catch ICloudArchiveRecoveryError.operationInProgress {}
        do { _ = try await store.resumeOriginalICloudAccountAfterEntitlementCheck(accountID: oldAccount.id, confirmed: true); XCTFail("Concurrent resume") }
        catch ICloudSameAccountResumeError.operationInProgress {}
        await gate.open(); let review = try await operation.value
        await store.discardICloudArchiveRecoveryReview(id: review.id)
    }
    func testCancellingPreparationNeverCreatesArchiveAndCanRetry() async throws {
        let before = try rows(), gate = ArchiveFlowGate(); await oldSync.holdPrepare(gate)
        let operation = Task { try await prepare() }; try await wait(gate)
        operation.cancel(); await gate.open()
        do { _ = try await operation.value; XCTFail("Cancelled preparation") } catch is CancellationError {}
        XCTAssertEqual(try rows(), before)
    }
    func testCancelBeforeCommitPreservesOldLibraryAndConsumesReview() async throws {
        let review = try await prepare(), before = try rows(), gate = ArchiveFlowGate(); await oldSync.holdExecute(gate)
        let operation = Task { try await execute(review) }; try await wait(gate)
        operation.cancel(); await gate.open()
        do { _ = try await operation.value; XCTFail("Cancelled execution") } catch is CancellationError {}
        XCTAssertEqual(try rows(), before)
        do { _ = try await execute(review); XCTFail("Cancelled review is consumed") } catch ICloudArchiveRecoveryError.staleReview {}
    }
    func testCancellationAfterCommitStillProjectsCompletedLocalArchive() async throws {
        let review = try await prepare(), gate = ArchiveFlowGate(); await oldSync.holdCommitted(gate)
        let operation = Task { try await execute(review) }; try await wait(gate)
        operation.cancel(); await gate.open()
        let result = try await operation.value
        XCTAssertNotNil(result.syncWarning)
        XCTAssertEqual(store.accounts.first { $0.id == oldAccount.id }?.isArchived, true)
        XCTAssertEqual(store.activeAccountID, result.newAccountID)
        let events = await newSync.snapshot(); XCTAssertTrue(events.isEmpty)
    }
    func testDisablingAccountDuringReviewInvalidatesCommit() async throws {
        let review = try await prepare()
        try await store.setAccountEnabled(accountID: oldAccount.id, isEnabled: false)
        let before = try rows()
        do { _ = try await execute(review); XCTFail("Disabled source") } catch ICloudArchiveRecoveryError.staleReview {}
        XCTAssertEqual(try rows(), before)
    }
    func testPrepareWaitsForCancelledApplicationRefreshToFinish() async throws {
        let gate = ArchiveFlowGate(); await oldSync.holdRefresh(gate)
        let provider = await store.syncCoordinator.provider(for: oldAccount.id) as! ICloudAccountProvider
        let refresh = Task { try await provider.refresh(reason: .manual) }; try await wait(gate)
        let recovery = Task { try await prepare() }
        try await Task.sleep(for: .milliseconds(50))
        let events = await oldSync.snapshot(); XCTAssertTrue(events.contains("stop")); XCTAssertFalse(events.contains("prepare"))
        await gate.open()
        do { _ = try await refresh.value; XCTFail("Cancelled refresh") } catch is CancellationError {}
        let review = try await recovery.value
        let after = await oldSync.snapshot(); XCTAssertTrue(after.contains("prepare"))
        await store.discardICloudArchiveRecoveryReview(id: review.id)
    }
    func testUnentitledPublicEntriesFailBeforeSyncOrPersistence() async throws {
        guard !ICloudSyncEngineDriver.isEntitled else { throw XCTSkip("Entitled test runner") }
        let before = try rows()
        do { _ = try await store.prepareICloudArchiveRecovery(accountID: oldAccount.id, connectionConfirmed: true); XCTFail("Entitlement required") } catch ICloudEngineError.notEntitled {}
        do { _ = try await store.executeICloudArchiveRecovery(reviewID: UUID(), archiveConfirmed: true); XCTFail("Entitlement required") } catch ICloudEngineError.notEntitled {}
        let driver = ICloudSyncEngineDriver(repository: .init(database: store.libraryDatabase, accountID: oldAccount.id))
        do { _ = try await driver.prepareArchiveRecovery(); XCTFail("Driver requires entitlement") } catch ICloudEngineError.notEntitled {}
        let events = await oldSync.snapshot(); XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(try rows(), before)
    }
    func testRecoveryMessagesContainNoPrivateSourceOrTargetValues() {
        for error in [ICloudArchiveRecoveryError.connectionConfirmationRequired, .archiveConfirmationRequired, .unavailableSource,
                      .cloudNeedsReview, .staleReview, .expiredReview, .safetyLimit, .readonlyArchive, .operationInProgress] {
            let message = store.iCloudErrorMessage(error)
            XCTAssertFalse(message.contains("old-user")); XCTAssertFalse(message.contains("new-user")); XCTAssertFalse(message.contains("archive.example"))
        }
    }
}
