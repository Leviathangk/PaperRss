@preconcurrency import CloudKit
import Foundation
import GRDB

enum ICloudArchiveRecoveryError: Error, Sendable, Equatable {
    case unavailableSource, cloudNeedsReview, staleReview, expiredReview, safetyLimit, readonlyArchive
    case connectionConfirmationRequired, archiveConfirmationRequired, operationInProgress
    case cloudInitializationConfirmationRequired
}

/// Local counts only. Archival preserves every original row; this is not a
/// migration payload, cloud identity or an approval to delete data.
public struct ICloudArchiveReview: Sendable, Equatable {
    public let feeds: Int
    public let folders: Int
    public let articles: Int
    public let starredArticles: Int
    public let missingIdentities: Int
    public let aiArtifacts: Int
}

public struct ICloudArchiveRecoveryReview: Identifiable, Sendable {
    public let id: UUID
    public let counts: ICloudArchiveReview
    public let preparedAt: Date
    public let needsCloudInitialization: Bool
}

public struct ICloudArchiveRecoveryResult: Sendable {
    public let newAccountID: String
    public let counts: ICloudArchiveReview
    public let syncWarning: String?
}

extension ICloudRecoveryReview {
    public var canArchiveAndRecover: Bool {
        isEnabled && hasSyncScope && captureEnabled &&
        [.accountChanged, .rootChanged, .rootMissing, .resetReview].contains(pause) &&
        (resetProgress == .none || resetProgress == .cloudReady)
    }
}

struct ICloudArchiveSource: Sendable, Equatable {
    let account: AccountRecord
    let scope: [String: DatabaseValue]
    let fingerprint: String
    let generation: String
    let pause: String
    let resetOperation: Data?
    let review: ICloudArchiveReview
}

/// Implementations must read and fully decode the current user's root, check
/// that user's fingerprint around the request, and never create/delete roots
/// or zones. The existing bound-user transport cannot adopt another user.
struct ICloudArchiveCloudObservation: Sendable {
    let fingerprint: String
    let root: ICloudResidueRootObservation
    let zones: [CKRecordZone.ID]
    /// nil means unverified, including observations of an existing root.
    let legacySnapshotExists: Bool?

    init(fingerprint: String, root: ICloudResidueRootObservation, zones: [CKRecordZone.ID],
         legacySnapshotExists: Bool? = nil) {
        self.fingerprint = fingerprint; self.root = root; self.zones = zones
        self.legacySnapshotExists = legacySnapshotExists
    }

    var isVerifiedEmpty: Bool {
        root == .missing && legacySnapshotExists == false &&
        !zones.contains { ICloudGenerationZone.isOwnedDataZoneName($0.zoneName) }
    }
}
protocol ICloudArchiveCloudReading: Sendable {
    func observe() async throws -> ICloudArchiveCloudObservation
}

/// The driver keeps the actual plan behind an exclusive recovery lifecycle.
/// No automatic refresh, migration or SDK delegate mints this.
struct ICloudArchiveRecoveryPlan: Sendable {
    let id = UUID()
    fileprivate let database: LibraryDatabase
    fileprivate let source: ICloudArchiveSource
    fileprivate let cloud: ICloudArchiveCloudObservation
    fileprivate let expires: ContinuousClock.Instant
    fileprivate let emptyGenerationProposal: String?
    var review: ICloudArchiveReview { source.review }
    var needsCloudInitialization: Bool { cloud.isVerifiedEmpty }
}

struct ICloudArchiveRecoveryCoordinator: Sendable {
    let database: LibraryDatabase
    let accountID: String
    let transport: any ICloudArchiveCloudReading
    var timeLimit: Duration = .seconds(30)
    var reviewLifetime: Duration = .seconds(600)
    var zoneLimit = 5_000

    func prepare(cancellation: ICloudResumeCancellation = .init()) async throws -> ICloudArchiveRecoveryPlan {
        try await withTaskCancellationHandler(operation: {
            let deadline = try budget(cancellation)
            let source = try await snapshot()
            let cloud = try await verify(source, deadline: deadline, cancellation: cancellation)
            return .init(database: database, source: source, cloud: cloud,
                         expires: ContinuousClock.now.advanced(by: reviewLifetime),
                         emptyGenerationProposal: cloud.isVerifiedEmpty ? UUID().uuidString : nil)
        }, onCancel: { cancellation.cancel() })
    }

    /// Metadata is rechecked after the user reviews the counts. The final
    /// writer transaction creates a fresh, empty scope and freezes the old
    /// account atomically; it never moves/copies an article or pending record.
    /// Verified-empty targets persist a proposal for normal bootstrap after
    /// this commit. No cloud mutation occurs in the archive transaction.
    func execute(_ plan: ICloudArchiveRecoveryPlan, initializeEmptyCloudConfirmed: Bool = false,
                 cancellation: ICloudResumeCancellation = .init()) async throws -> AccountRecord {
        try await withTaskCancellationHandler(operation: {
            guard plan.database === database, plan.source.account.id == accountID else {
                throw ICloudArchiveRecoveryError.staleReview
            }
            guard ContinuousClock.now < plan.expires else { throw ICloudArchiveRecoveryError.expiredReview }
            guard !plan.needsCloudInitialization || initializeEmptyCloudConfirmed else {
                throw ICloudArchiveRecoveryError.cloudInitializationConfirmationRequired
            }
            let deadline = min(try budget(cancellation), plan.expires)
            let cloud = try await verify(plan.source, deadline: deadline, cancellation: cancellation)
            guard sameCloud(cloud, plan.cloud) else { throw ICloudArchiveRecoveryError.staleReview }
            return try await database.writeAsync { db in
                try check(cancellation, deadline: deadline)
                guard try snapshot(in: db) == plan.source else { throw ICloudArchiveRecoveryError.staleReview }
                try db.execute(sql: "UPDATE icloud_sync_scope SET capture_enabled = 0, suppress_capture = 1 WHERE account_id = ?",
                               arguments: [accountID])
                let now = Date().timeIntervalSince1970
                try db.execute(sql: "UPDATE accounts SET is_enabled = 0, is_archived = 1, updated_at = ? WHERE id = ? AND is_archived = 0",
                               arguments: [now, accountID])
                guard db.changesCount == 1 else {
                    throw ICloudArchiveRecoveryError.staleReview
                }
                let generation: String?
                let initializedZones: Int
                let protocolVersion: Int
                if case .found(let root, _) = cloud.root {
                    generation = root.generation; initializedZones = 3; protocolVersion = root.protocolVersion
                } else if cloud.isVerifiedEmpty, let proposal = plan.emptyGenerationProposal {
                    try ICloudCloudRoot(generation: proposal, phase: .ready).validate()
                    generation = nil; initializedZones = 0; protocolVersion = 2
                } else { throw ICloudArchiveRecoveryError.staleReview }
                let account = AccountRecord(id: "icloud-\(UUID().uuidString)", type: AccountType.iCloud.rawValue,
                                            displayName: "iCloud", createdAt: now, updatedAt: now)
                try account.insert(db)
                try db.execute(sql: """
                    INSERT INTO icloud_sync_scope(account_id, capture_enabled, user_fingerprint, cloud_generation, initialized_zones, cloud_generation_proposal, cloud_protocol_version)
                    VALUES (?, 1, ?, ?, ?, ?, ?);
                    """, arguments: [account.id, cloud.fingerprint, generation, initializedZones, plan.emptyGenerationProposal, protocolVersion])
                try ICloudRecordSchema.ensureDeviceIdentity(accountID: account.id, in: db)
                try check(cancellation, deadline: deadline)
                return account
            }
        }, onCancel: { cancellation.cancel() })
    }

    func snapshot() async throws -> ICloudArchiveSource {
        try await database.readAsync { try snapshot(in: $0) }
    }

    private func snapshot(in db: Database) throws -> ICloudArchiveSource {
        guard let account = try AccountRecord.fetchOne(db, key: accountID),
              account.type == AccountType.iCloud.rawValue, account.isEnabled, !account.isArchived,
              account.endpointURL == nil, account.username == nil,
              let scope = try Row.fetchOne(db, sql: "SELECT * FROM icloud_sync_scope WHERE account_id = ?", arguments: [accountID]),
              scope["capture_enabled"] as Bool, !(scope["suppress_capture"] as Bool),
              let fingerprint: String = scope["user_fingerprint"], !fingerprint.isEmpty, fingerprint.utf8.count <= 256,
              let generation: String = scope["cloud_generation"],
              let pause: String = scope["pause_reason"],
              ["accountChanged", "cloudGenerationChanged", "cloudRootMissing", "cloudResetReview"].contains(pause)
        else { throw ICloudArchiveRecoveryError.unavailableSource }
        try ICloudCloudRoot(generation: generation, phase: .ready).validate()
        let resetValue: DatabaseValue = scope["cloud_reset_operation"]
        let resetOperation: Data?
        if resetValue != .null {
            guard case .blob(let data) = resetValue.storage else { throw ICloudArchiveRecoveryError.unavailableSource }
            let operation = try ICloudCloudResetOperation.decode(data)
            guard operation.stage == .cloudReady, pause == "cloudResetReview",
                  operation.approval.previousGeneration == generation,
                  operation.approval.previousProtocolVersion == scope["cloud_protocol_version"] as Int,
                  operation.approval.systemFingerprint == fingerprint else {
                throw ICloudArchiveRecoveryError.unavailableSource
            }
            resetOperation = data
        } else {
            guard pause != "cloudResetReview" else { throw ICloudArchiveRecoveryError.unavailableSource }
            resetOperation = nil
        }
        let counts = try Row.fetchOne(db, sql: """
            SELECT
                (SELECT COUNT(*) FROM feeds WHERE account_id = ?) AS feeds,
                (SELECT COUNT(*) FROM folders WHERE account_id = ?) AS folders,
                (SELECT COUNT(*) FROM items i JOIN articles a ON a.item_id = i.id WHERE i.account_id = ?) AS articles,
                (SELECT COUNT(*) FROM items i JOIN article_states s ON s.item_id = i.id WHERE i.account_id = ? AND s.is_starred = 1) AS starred,
                (SELECT COUNT(*) FROM ai_artifacts a WHERE a.account_id = ? OR EXISTS (
                    SELECT 1 FROM items i WHERE i.account_id = ? AND (i.id = a.item_id OR i.id = a.subject_key))) AS ai
            """, arguments: [accountID, accountID, accountID, accountID, accountID, accountID])!
        var missing = 0
        let identities = try Row.fetchCursor(db, sql: "SELECT source_item_id FROM items WHERE account_id = ?", arguments: [accountID])
        while let item = try identities.next() {
            if !ICloudSyncIdentity.hasSourceItemIdentity(item["source_item_id"]) { missing += 1 }
        }
        return .init(account: account, scope: Dictionary(uniqueKeysWithValues: scope),
            fingerprint: fingerprint, generation: generation, pause: pause, resetOperation: resetOperation,
            review: .init(feeds: counts["feeds"], folders: counts["folders"],
            articles: counts["articles"], starredArticles: counts["starred"], missingIdentities: missing, aiArtifacts: counts["ai"]))
    }

    private func verify(_ source: ICloudArchiveSource, deadline: ContinuousClock.Instant,
                        cancellation: ICloudResumeCancellation) async throws -> ICloudArchiveCloudObservation {
        var previous: ICloudArchiveCloudObservation?
        for _ in 0..<2 {
            try check(cancellation, deadline: deadline)
            guard try await snapshot() == source else { throw ICloudArchiveRecoveryError.staleReview }
            let cloud = try await transport.observe()
            try check(cancellation, deadline: deadline)
            guard cloud.zones.count <= zoneLimit else { throw ICloudArchiveRecoveryError.safetyLimit }
            guard try await snapshot() == source else { throw ICloudArchiveRecoveryError.staleReview }
            try validate(cloud, source: source)
            if let previous, !sameCloud(previous, cloud) { throw ICloudArchiveRecoveryError.cloudNeedsReview }
            previous = cloud
        }
        return previous!
    }

    private func validate(_ cloud: ICloudArchiveCloudObservation, source: ICloudArchiveSource) throws {
        guard !cloud.fingerprint.isEmpty, cloud.fingerprint.utf8.count <= 256 else {
            throw ICloudArchiveRecoveryError.cloudNeedsReview
        }
        if cloud.isVerifiedEmpty {
            // An empty library is not proof that a cloudReady reset completed,
            // and cannot resume the original scope with its pending history.
            let sameUser = cloud.fingerprint == source.fingerprint
            guard source.resetOperation == nil,
                  sameUser ? source.pause == "cloudRootMissing" : source.pause == "accountChanged" else {
                throw ICloudArchiveRecoveryError.cloudNeedsReview
            }
            return
        }
        guard
              case .found(let root, let tag) = cloud.root, !tag.isEmpty, root.phase == .ready else {
            throw ICloudArchiveRecoveryError.cloudNeedsReview
        }
        try root.validate()
        let required = try Set(ICloudRecordZone.allCases.map { try ICloudGenerationZone.id($0, generation: root.generation) })
        guard required.isSubset(of: Set(cloud.zones)) else { throw ICloudArchiveRecoveryError.cloudNeedsReview }
        let sameUser = cloud.fingerprint == source.fingerprint
        if let data = source.resetOperation {
            let operation = try ICloudCloudResetOperation.decode(data)
            guard sameUser, root == operation.approval.replacementRoot else {
                throw ICloudArchiveRecoveryError.cloudNeedsReview
            }
        } else if !sameUser {
            guard source.pause == "accountChanged" else {
                throw ICloudArchiveRecoveryError.cloudNeedsReview
            }
        } else if root.generation == source.generation {
            // The same-user/same-generation path must use its existing scope.
            throw ICloudArchiveRecoveryError.cloudNeedsReview
        }
    }

    private func sameCloud(_ a: ICloudArchiveCloudObservation, _ b: ICloudArchiveCloudObservation) -> Bool {
        a.fingerprint == b.fingerprint && a.root == b.root && Set(a.zones) == Set(b.zones) &&
        a.legacySnapshotExists == b.legacySnapshotExists
    }
    private func budget(_ cancellation: ICloudResumeCancellation) throws -> ContinuousClock.Instant {
        try Task.checkCancellation(); try cancellation.check()
        guard timeLimit > .zero, reviewLifetime > .zero, zoneLimit >= 2 else { throw ICloudArchiveRecoveryError.safetyLimit }
        return ContinuousClock.now.advanced(by: timeLimit)
    }
    private func check(_ cancellation: ICloudResumeCancellation, deadline: ContinuousClock.Instant) throws {
        try cancellation.check()
        guard ContinuousClock.now < deadline else { throw ICloudArchiveRecoveryError.safetyLimit }
    }
}
