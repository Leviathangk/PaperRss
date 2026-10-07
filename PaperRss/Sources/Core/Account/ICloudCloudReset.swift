import Foundation

enum ICloudCloudResetError: LocalizedError, Sendable, Equatable {
    case invalidOperation, approvalMismatch, operationInProgress, operationChanged, unexpectedRoot
    var errorDescription: String? { ICloudSyncFailure.message(for: self) }
}

/// Supplied only after separately reviewing replacement and whether the old
/// cloud scope is preserved or cleared. Account activation and automatic sync
/// never construct or persist this approval. Legacy approvals remain clear-v2.
struct ICloudCloudResetApproval: Codable, Sendable, Equatable {
    enum PreviousDataDisposition: String, Codable, Sendable { case delete, preserve }
    let operationID: String
    let previousGeneration: String
    let replacementGeneration: String
    let systemFingerprint: String
    let previousProtocolVersion: Int
    let replacementProtocolVersion: Int
    let previousDataDisposition: PreviousDataDisposition

    init(operationID: String, previousGeneration: String, replacementGeneration: String, systemFingerprint: String,
         previousProtocolVersion: Int = 2, replacementProtocolVersion: Int = 2,
         previousDataDisposition: PreviousDataDisposition = .delete) {
        self.operationID = operationID; self.previousGeneration = previousGeneration
        self.replacementGeneration = replacementGeneration; self.systemFingerprint = systemFingerprint
        self.previousProtocolVersion = previousProtocolVersion; self.replacementProtocolVersion = replacementProtocolVersion
        self.previousDataDisposition = previousDataDisposition
    }
    enum CodingKeys: String, CodingKey {
        case operationID, previousGeneration, replacementGeneration, systemFingerprint
        case previousProtocolVersion, replacementProtocolVersion
        case previousDataDisposition
    }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        operationID = try values.decode(String.self, forKey: .operationID)
        previousGeneration = try values.decode(String.self, forKey: .previousGeneration)
        replacementGeneration = try values.decode(String.self, forKey: .replacementGeneration)
        systemFingerprint = try values.decode(String.self, forKey: .systemFingerprint)
        // Already persisted approvals predate the retention writer contract.
        // They can never be reinterpreted as approval to create a v3 library.
        previousProtocolVersion = values.contains(.previousProtocolVersion) ? try values.decode(Int.self, forKey: .previousProtocolVersion) : 2
        replacementProtocolVersion = values.contains(.replacementProtocolVersion) ? try values.decode(Int.self, forKey: .replacementProtocolVersion) : 2
        previousDataDisposition = values.contains(.previousDataDisposition) ? try values.decode(PreviousDataDisposition.self, forKey: .previousDataDisposition) : .delete
    }

    var previousRoot: ICloudCloudRoot { .init(generation: previousGeneration, phase: .ready, protocolVersion: previousProtocolVersion) }
    var resettingRoot: ICloudCloudRoot { .init(generation: replacementGeneration, phase: .resetting, protocolVersion: replacementProtocolVersion) }
    var replacementRoot: ICloudCloudRoot { .init(generation: replacementGeneration, phase: .ready, protocolVersion: replacementProtocolVersion) }

    func validate() throws {
        guard let id = UUID(uuidString: operationID), id.uuidString == operationID,
              !systemFingerprint.isEmpty, systemFingerprint.utf8.count <= 256,
              previousGeneration != replacementGeneration,
              replacementProtocolVersion >= previousProtocolVersion,
              previousDataDisposition != .preserve || replacementProtocolVersion == 3 else { throw ICloudCloudResetError.invalidOperation }
        try previousRoot.validate(); try replacementRoot.validate()
    }
}

struct ICloudCloudResetOperation: Codable, Sendable, Equatable {
    enum Stage: Int, Codable, Sendable, CaseIterable {
        case prepared, rootPublished, libraryCreated, articlesCreated, libraryDeleted, articlesDeleted, cloudReady
        case previousRetained
    }
    let schemaVersion: Int
    let approval: ICloudCloudResetApproval
    var stage: Stage

    init(approval: ICloudCloudResetApproval) {
        schemaVersion = 1; self.approval = approval; stage = .prepared
    }
    func validate() throws {
        guard schemaVersion == 1 else { throw ICloudCloudResetError.invalidOperation }
        try approval.validate()
        if stage == .previousRetained {
            guard approval.previousDataDisposition == .preserve else { throw ICloudCloudResetError.invalidOperation }
        }
        if stage == .libraryDeleted || stage == .articlesDeleted {
            guard approval.previousDataDisposition == .delete else { throw ICloudCloudResetError.invalidOperation }
        }
    }
    func serialized() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let value = try encoder.encode(self)
        guard value.count <= 8 * 1024 else { throw ICloudCloudResetError.invalidOperation }
        return value
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 8 * 1024 else { throw ICloudCloudResetError.invalidOperation }
        do {
            let result = try JSONDecoder().decode(Self.self, from: data)
            try result.validate()
            return result
        } catch { throw ICloudCloudResetError.invalidOperation }
    }
}

/// The revision is opaque server system fields, never a locally guessed tag.
struct ICloudCloudResetRootSnapshot: Sendable {
    let root: ICloudCloudRoot
    let systemFields: Data
    let systemFingerprint: String
}

protocol ICloudCloudResetTransport: Sendable {
    func readRoot() async throws -> ICloudCloudResetRootSnapshot
    func writeRoot(_ root: ICloudCloudRoot, replacing snapshot: ICloudCloudResetRootSnapshot) async throws
    func createZone(_ zone: ICloudRecordZone, generation: String) async throws
    func deleteZone(_ zone: ICloudRecordZone, generation: String) async throws
}
