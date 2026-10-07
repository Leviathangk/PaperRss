@preconcurrency import CloudKit
import Foundation
import GRDB

enum ICloudSameAccountResumeError: Error, Sendable, Equatable {
    case confirmationRequired, unavailableScope, cloudNeedsReview, operationInProgress, safetyLimit
}

/// Resuming the already approved account does not migrate history or adopt a
/// different cloud generation. No identity or cloud metadata reaches the UI.
public struct ICloudSameAccountResumeResult: Sendable {
    public let isPaused: Bool
    public let syncWarning: String?
}

extension ICloudRecoveryReview {
    public var canResumeOriginalAccount: Bool {
        isEnabled && hasSyncScope && captureEnabled && pause == .accountChanged && resetProgress == .none
    }
}

extension ICloudRecordRepository {
    func sameAccountResumeContext() async throws -> ICloudResidueContext {
        try await database.readAsync { try self.sameAccountResumeContext(in: $0) }
    }

    private func sameAccountResumeContext(in db: Database) throws -> ICloudResidueContext {
        try requireScope(in: db, permitsPause: true)
        guard try AccountRecord.fetchOne(db, key: accountID)?.isEnabled == true,
              let row = try Row.fetchOne(db, sql: """
                SELECT user_fingerprint, cloud_generation, cloud_protocol_version, pause_reason,
                    cloud_reset_operation IS NOT NULL AS has_reset_operation, suppress_capture
                FROM icloud_sync_scope WHERE account_id = ?;
                """, arguments: [accountID]),
              row["pause_reason"] as String? == "accountChanged",
              !(row["has_reset_operation"] as Bool),
              !(row["suppress_capture"] as Bool),
              let fingerprint: String = row["user_fingerprint"], !fingerprint.isEmpty, fingerprint.utf8.count <= 256,
              let generation: String = row["cloud_generation"] else {
            throw ICloudSameAccountResumeError.unavailableScope
        }
        try ICloudCloudRoot(generation: generation, phase: .ready).validate()
        return .init(accountID: accountID, systemFingerprint: fingerprint, boundGeneration: generation,
                     referenceGeneration: generation, pauseReason: "accountChanged", resetOperation: nil,
                     boundProtocolVersion: row["cloud_protocol_version"])
    }

    /// A single conditional local write. All cached data, versions, pending
    /// changes and checkpoints are retained. Cancellation crosses the GRDB queue.
    func resumeSameAccount(_ context: ICloudResidueContext, cancellation: ICloudResumeCancellation,
                           deadline: ContinuousClock.Instant) async throws {
        try await database.writeAsync { db in
            try cancellation.check()
            guard ContinuousClock.now < deadline else { throw ICloudSameAccountResumeError.safetyLimit }
            guard try self.sameAccountResumeContext(in: db) == context else {
                throw ICloudSameAccountResumeError.unavailableScope
            }
            try db.execute(sql: "UPDATE icloud_sync_scope SET pause_reason = NULL WHERE account_id = ? AND pause_reason = 'accountChanged'",
                           arguments: [self.accountID])
            guard db.changesCount == 1 else { throw ICloudSameAccountResumeError.unavailableScope }
            try cancellation.check()
            guard ContinuousClock.now < deadline else { throw ICloudSameAccountResumeError.safetyLimit }
        }
    }
}

/// This signal also lets the driver invalidate an in-flight recovery when its
/// lifecycle stops. Task.isCancelled alone cannot inspect the caller on GRDB.
final class ICloudResumeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws { if lock.withLock({ cancelled }) { throw CancellationError() } }
}

/// Only called after explicit confirmation. The read-only transport verifies
/// the current system fingerprint before/after each metadata observation.
struct ICloudSameAccountResumeCoordinator: Sendable {
    let repository: ICloudRecordRepository
    let transport: any ICloudResidueMetadataReading
    var timeLimit: Duration = .seconds(30)
    var zoneLimit = 5_000

    func resume(cancellation: ICloudResumeCancellation = .init()) async throws {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation(); try cancellation.check()
            guard timeLimit > .zero, zoneLimit >= 2 else { throw ICloudSameAccountResumeError.safetyLimit }
            let deadline = ContinuousClock.now.advanced(by: timeLimit)
            let context = try await repository.sameAccountResumeContext()
            let first = try await read(context, deadline: deadline, cancellation: cancellation)
            let second = try await read(context, deadline: deadline, cancellation: cancellation)
            guard first.root == second.root, Set(first.zones) == Set(second.zones) else {
                throw ICloudSameAccountResumeError.cloudNeedsReview
            }
            try cancellation.check()
            guard ContinuousClock.now < deadline else { throw ICloudSameAccountResumeError.safetyLimit }
            // The normal driver still validates the full root and fetches
            // changes before its delegate may supply an outgoing record batch.
            try await repository.resumeSameAccount(context, cancellation: cancellation, deadline: deadline)
        }, onCancel: { cancellation.cancel() })
    }

    private func read(_ context: ICloudResidueContext, deadline: ContinuousClock.Instant,
                      cancellation: ICloudResumeCancellation) async throws -> ICloudResidueMetadata {
        try cancellation.check()
        guard ContinuousClock.now < deadline else { throw ICloudSameAccountResumeError.safetyLimit }
        guard try await repository.sameAccountResumeContext() == context else {
            throw ICloudSameAccountResumeError.unavailableScope
        }
        let value = try await transport.metadata(for: context)
        try cancellation.check()
        guard ContinuousClock.now < deadline, value.zones.count <= zoneLimit else {
            throw ICloudSameAccountResumeError.safetyLimit
        }
        guard try await repository.sameAccountResumeContext() == context else {
            throw ICloudSameAccountResumeError.unavailableScope
        }
        guard case .found(let root, let tag) = value.root, !tag.isEmpty,
              root.phase == .ready, root.generation == context.boundGeneration,
              root.protocolVersion == context.boundProtocolVersion else {
            throw ICloudSameAccountResumeError.cloudNeedsReview
        }
        try root.validate()
        let required = try Set(ICloudRecordZone.allCases.map { try ICloudGenerationZone.id($0, generation: root.generation) })
        guard required.isSubset(of: Set(value.zones)) else { throw ICloudSameAccountResumeError.cloudNeedsReview }
        return value
    }
}
