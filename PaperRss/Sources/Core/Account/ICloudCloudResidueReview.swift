@preconcurrency import CloudKit
import Foundation
import GRDB

/// Metadata observations, not a proof of erasure or an approval to recover.
/// No zone names, UUIDs, account fingerprints or record fields leave this API.
public struct ICloudCloudResidueReview: Sendable, Equatable {
    public enum RootStatus: Sendable, Equatable {
        case unbound, ready, resetting, missing, incompatible, differentGeneration, changedDuringReview
    }
    public enum LegacySnapshot: Sendable, Equatable {
        case observed, notObserved
    }
    public let scannedAt: Date
    public let isComplete: Bool
    public let reachedSafetyLimit: Bool
    public let didChangeDuringReview: Bool
    public let rootStatus: RootStatus
    public let currentGenerationZones: Int
    public let otherGenerationZones: Int
    public let legacyZones: Int
    public let unrecognizedOwnedZones: Int
    public let legacySnapshot: LegacySnapshot
}

struct ICloudResidueContext: Sendable, Equatable {
    let accountID: String
    let systemFingerprint: String
    let boundGeneration: String?
    let referenceGeneration: String?
    let pauseReason: String?
    let resetOperation: Data?
    let boundProtocolVersion: Int

    init(accountID: String, systemFingerprint: String, boundGeneration: String?, referenceGeneration: String?,
         pauseReason: String?, resetOperation: Data?, boundProtocolVersion: Int = 2) {
        self.accountID = accountID; self.systemFingerprint = systemFingerprint
        self.boundGeneration = boundGeneration; self.referenceGeneration = referenceGeneration
        self.pauseReason = pauseReason; self.resetOperation = resetOperation
        self.boundProtocolVersion = boundProtocolVersion
    }
}

enum ICloudResidueRootObservation: Sendable, Equatable {
    case found(ICloudCloudRoot, changeTag: String), missing, incompatible
}

struct ICloudResidueMetadata: Sendable {
    let root: ICloudResidueRootObservation
    let zones: [CKRecordZone.ID]
    let hasLegacySnapshot: Bool
}

protocol ICloudResidueMetadataReading: Sendable {
    func metadata(for context: ICloudResidueContext) async throws -> ICloudResidueMetadata
}

extension ICloudRecordRepository {
    /// A paused scope may inspect metadata without resuming normal sync. A
    /// changed/disabled account or invalid approval must fail before CloudKit.
    func cloudResidueContext() async throws -> ICloudResidueContext {
        try await database.readAsync { db in
            try self.requireScope(in: db, permitsPause: true)
            guard try AccountRecord.fetchOne(db, key: self.accountID)?.isEnabled == true,
                  let row = try Row.fetchOne(db, sql: """
                    SELECT user_fingerprint, cloud_generation, cloud_protocol_version, pause_reason, cloud_reset_operation
                    FROM icloud_sync_scope WHERE account_id = ?;
                    """, arguments: [self.accountID]),
                  let fingerprint: String = row["user_fingerprint"],
                  !fingerprint.isEmpty, fingerprint.utf8.count <= 256 else {
                throw ICloudRecordError.unavailableScope
            }
            let reason: String? = row["pause_reason"]
            guard reason != "accountChanged" else { throw ICloudRecordError.accountChanged }
            let bound: String? = row["cloud_generation"]
            if let bound { try ICloudCloudRoot(generation: bound, phase: .ready).validate() }
            let data: Data? = row["cloud_reset_operation"]
            var reference = bound
            if let data {
                let operation = try ICloudCloudResetOperation.decode(data)
                guard bound == operation.approval.previousGeneration,
                      fingerprint == operation.approval.systemFingerprint,
                      reason == (operation.stage == .cloudReady ? "cloudResetReview" : "cloudResetRequested") else {
                    throw ICloudCloudResetError.approvalMismatch
                }
                reference = operation.approval.replacementGeneration
            } else if reason == "cloudResetReview" || reason == "cloudResetRequested" {
                throw ICloudCloudResetError.invalidOperation
            }
            return .init(accountID: self.accountID, systemFingerprint: fingerprint,
                boundGeneration: bound, referenceGeneration: reference, pauseReason: reason, resetOperation: data,
                boundProtocolVersion: row["cloud_protocol_version"])
        }
    }
}

/// Two independent observations detect changes during review. Their agreement
/// cannot rule out later requests, another device, or an ABA between samples.
struct ICloudCloudResidueScanner: Sendable {
    let repository: ICloudRecordRepository
    let transport: any ICloudResidueMetadataReading
    var now: @Sendable () -> Date = { Date() }
    var timeLimit: TimeInterval = 30
    var zoneLimit = 5_000

    func scan() async throws -> ICloudCloudResidueReview {
        let started = now()
        let context = try await repository.cloudResidueContext()
        let first = try await read(context)
        let firstExceeded = now().timeIntervalSince(started) >= timeLimit || first.zones.count > zoneLimit
        if firstExceeded {
            return try report(first, second: nil, context: context, reachedLimit: true)
        }
        let second = try await read(context)
        let exceeded = now().timeIntervalSince(started) >= timeLimit || second.zones.count > zoneLimit
        return try report(first, second: second, context: context, reachedLimit: exceeded)
    }

    private func read(_ context: ICloudResidueContext) async throws -> ICloudResidueMetadata {
        try Task.checkCancellation()
        guard try await repository.cloudResidueContext() == context else { throw ICloudCloudResetError.operationChanged }
        let result = try await transport.metadata(for: context)
        try Task.checkCancellation()
        guard try await repository.cloudResidueContext() == context else { throw ICloudCloudResetError.operationChanged }
        return result
    }

    private func report(_ first: ICloudResidueMetadata, second: ICloudResidueMetadata?,
                        context: ICloudResidueContext, reachedLimit: Bool) throws -> ICloudCloudResidueReview {
        let limit = max(0, zoneLimit)
        let firstIDs = Set(first.zones.prefix(limit))
        let secondIDs = Set(second?.zones.prefix(limit) ?? [])
        let allIDs = firstIDs.union(secondIDs)
        let changed = second.map {
            first.root != $0.root || firstIDs != secondIDs || first.hasLegacySnapshot != $0.hasLegacySnapshot
        } ?? false
        let exceeded = reachedLimit || allIDs.count > limit
        var current = 0, other = 0, legacy = 0, unknown = 0
        // Bound processing independently of the SDK's zone-list size.
        for id in allIDs.sorted(by: {
            ($0.ownerName, $0.zoneName) < ($1.ownerName, $1.zoneName)
        }).prefix(limit) {
            guard id.ownerName == CKCurrentUserDefaultName else { continue }
            do {
                switch try ICloudGenerationZone.classify(id, generation: context.referenceGeneration) {
                case .current: current += 1
                case .otherGeneration: other += 1
                case .legacy: legacy += 1
                case .unrelated: break
                }
            } catch {
                if ICloudGenerationZone.isOwnedDataZoneName(id.zoneName) { unknown += 1 }
                else { throw error }
            }
        }
        let root = second?.root ?? first.root
        let status: ICloudCloudResidueReview.RootStatus
        if second?.root != nil, second?.root != first.root {
            status = .changedDuringReview
        } else {
            switch root {
            case .missing: status = .missing
            case .incompatible: status = .incompatible
            case .found(let value, _):
                if context.referenceGeneration == nil { status = .unbound }
                else if value.generation != context.referenceGeneration { status = .differentGeneration }
                else if value.generation == context.boundGeneration, value.protocolVersion != context.boundProtocolVersion { status = .incompatible }
                else { status = value.phase == .ready ? .ready : .resetting }
            }
        }
        return .init(scannedAt: now(),
            isComplete: second != nil && !exceeded && !changed && root != .incompatible && status != .incompatible,
            reachedSafetyLimit: exceeded, didChangeDuringReview: changed, rootStatus: status,
            currentGenerationZones: current, otherGenerationZones: other, legacyZones: legacy,
            unrecognizedOwnedZones: unknown,
            legacySnapshot: first.hasLegacySnapshot || second?.hasLegacySnapshot == true ? .observed : .notObserved)
    }
}
