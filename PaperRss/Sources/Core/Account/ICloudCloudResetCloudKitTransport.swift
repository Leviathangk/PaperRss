@preconcurrency import CloudKit
import Foundation

/// Inert until called by the separately approved coordinator. It never creates
/// a missing root, adopts old layouts, deletes the control zone, or copies data.
struct ICloudCloudResetCloudKitTransport: ICloudCloudResetTransport {
    let repository: ICloudRecordRepository
    let operationID: String

    private func verifiedContext() async throws -> (CKDatabase, ICloudCloudResetOperation) {
        try Task.checkCancellation()
        let before = try await repository.cloudResetOperation(id: operationID)
        let fingerprint = try await ICloudSyncEngineDriver.systemUserFingerprint()
        try Task.checkCancellation()
        guard fingerprint == before.approval.systemFingerprint else {
            try repository.pause(reason: "accountChanged")
            throw ICloudRecordError.accountChanged
        }
        let after = try await repository.cloudResetOperation(id: operationID)
        guard before == after else { throw ICloudCloudResetError.operationChanged }
        return (CKContainer(identifier: ICloudSyncEngineDriver.containerIdentifier).privateCloudDatabase, after)
    }

    private func revalidate(_ expected: ICloudCloudResetOperation) async throws {
        let (_, current) = try await verifiedContext()
        guard current == expected else { throw ICloudCloudResetError.operationChanged }
    }

    func readRoot() async throws -> ICloudCloudResetRootSnapshot {
        let (database, operation) = try await verifiedContext()
        let record: CKRecord
        do { record = try await database.record(for: ICloudCloudRootCodec.recordID) }
        catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            throw ICloudRootError.rootMissing
        }
        try await revalidate(operation)
        return .init(root: try ICloudCloudRootCodec.decode(record), systemFields: ICloudRecordCodec.systemFields(record),
                     systemFingerprint: operation.approval.systemFingerprint)
    }

    func writeRoot(_ root: ICloudCloudRoot, replacing snapshot: ICloudCloudResetRootSnapshot) async throws {
        let (database, operation) = try await verifiedContext()
        guard snapshot.systemFingerprint == operation.approval.systemFingerprint else {
            throw ICloudRecordError.accountChanged
        }
        try Self.validateRootWrite(root, replacing: snapshot.root, operation: operation)
        let record = try Self.rootRecord(root, systemFields: snapshot.systemFields)
        try await revalidate(operation)
        // Conflicts are never forced. Resume fetches a fresh root and verifies
        // whether this exact operation won, failed ambiguously or was superseded.
        let result = try await database.modifyRecords(saving: [record], deleting: [],
            savePolicy: .ifServerRecordUnchanged, atomically: true)
        guard let response = result.saveResults[record.recordID] else { throw ICloudRecordError.persistenceFailed }
        guard try ICloudCloudRootCodec.decode(response.get()) == root else { throw ICloudCloudResetError.unexpectedRoot }
        try await revalidate(operation)
    }

    func createZone(_ zone: ICloudRecordZone, generation: String) async throws {
        let (database, operation) = try await verifiedContext()
        try Self.validateZoneMutation(zone, generation: generation, creating: true, operation: operation)
        try await requireResettingRoot(database: database, operation: operation)
        let id = try ICloudGenerationZone.id(zone, generation: generation)
        try await revalidate(operation)
        let result = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: id)], deleting: [])
        guard let response = result.saveResults[id] else { throw ICloudRecordError.persistenceFailed }
        guard try response.get().zoneID == id else { throw ICloudCloudResetError.invalidOperation }
        try await revalidate(operation)
    }

    func deleteZone(_ zone: ICloudRecordZone, generation: String) async throws {
        let (database, operation) = try await verifiedContext()
        try Self.validateZoneMutation(zone, generation: generation, creating: false, operation: operation)
        try await requireResettingRoot(database: database, operation: operation)
        let id = try ICloudGenerationZone.id(zone, generation: generation)
        try await revalidate(operation)
        do {
            let result = try await database.modifyRecordZones(saving: [], deleting: [id])
            guard let response = result.deleteResults[id] else { throw ICloudRecordError.persistenceFailed }
            try response.get()
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {
            // An already absent *approved old* zone is a successful replay.
        }
        try await revalidate(operation)
    }

    private func requireResettingRoot(database: CKDatabase, operation: ICloudCloudResetOperation) async throws {
        let record = try await database.record(for: ICloudCloudRootCodec.recordID)
        let root = try ICloudCloudRootCodec.decode(record)
        guard root == operation.approval.resettingRoot else {
            throw ICloudCloudResetError.unexpectedRoot
        }
        try await revalidate(operation)
    }

    static func validateRootWrite(_ desired: ICloudCloudRoot, replacing previous: ICloudCloudRoot,
                                  operation: ICloudCloudResetOperation) throws {
        try operation.validate(); try desired.validate(); try previous.validate()
        let approval = operation.approval
        let beginning = operation.stage == .prepared &&
            previous == approval.previousRoot && desired == approval.resettingRoot
        let finishedPrevious = (operation.stage == .articlesDeleted && approval.previousDataDisposition == .delete) ||
            (operation.stage == .previousRetained && approval.previousDataDisposition == .preserve)
        let finishing = finishedPrevious &&
            previous == approval.resettingRoot && desired == approval.replacementRoot
        guard beginning || finishing else { throw ICloudCloudResetError.approvalMismatch }
    }

    static func validateZoneMutation(_ zone: ICloudRecordZone, generation: String, creating: Bool,
                                     operation: ICloudCloudResetOperation) throws {
        try operation.validate()
        let expectedStage: ICloudCloudResetOperation.Stage
        if creating { expectedStage = zone == .library ? .rootPublished : .libraryCreated }
        else {
            guard operation.approval.previousDataDisposition == .delete else { throw ICloudCloudResetError.approvalMismatch }
            expectedStage = zone == .library ? .articlesCreated : .libraryDeleted
        }
        let expectedGeneration = creating ? operation.approval.replacementGeneration : operation.approval.previousGeneration
        guard operation.stage == expectedStage, generation == expectedGeneration else {
            throw ICloudCloudResetError.approvalMismatch
        }
    }

    /// Reset CAS must carry a real server tag. A fresh CKRecord with a nil tag
    /// is for empty-library initialization only, never an overwrite fallback.
    static func rootRecord(_ root: ICloudCloudRoot, systemFields: Data) throws -> CKRecord {
        try root.validate()
        let coder = try NSKeyedUnarchiver(forReadingFrom: systemFields)
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        guard let record = CKRecord(coder: coder), record.recordID == ICloudCloudRootCodec.recordID,
              record.recordType == ICloudCloudRootCodec.recordType,
              let tag = record.recordChangeTag, !tag.isEmpty else { throw ICloudCloudResetError.invalidOperation }
        record["schemaVersion"] = root.protocolVersion as NSNumber
        record["generation"] = root.generation as NSString
        record["phase"] = root.phase.rawValue as NSString
        return record
    }
}
