import Foundation

enum ICloudRootError: Error, Sendable, Equatable {
    case malformedRoot, unsupportedVersion, generationChanged, rootMissing
    case resetInProgress, legacyCloudRequiresReview
}

struct ICloudCloudRoot: Sendable, Equatable {
    enum Phase: String, Sendable { case ready, resetting }
    let generation: String
    let phase: Phase
    let protocolVersion: Int
    static let retentionProtocolVersion = 3

    init(generation: String, phase: Phase, protocolVersion: Int = 2) {
        self.generation = generation; self.phase = phase; self.protocolVersion = protocolVersion
    }

    func validate() throws {
        guard protocolVersion == 2 || protocolVersion == Self.retentionProtocolVersion else {
            throw ICloudRootError.unsupportedVersion
        }
        guard let uuid = UUID(uuidString: generation), uuid.uuidString == generation else {
            throw ICloudRootError.malformedRoot
        }
    }
}

enum ICloudRootLookup: Sendable {
    case found(ICloudCloudRoot)
    case missing(hasExistingData: Bool)
}

protocol ICloudRootTransport: Sendable {
    func lookupRoot() async throws -> ICloudRootLookup
    /// A competing first initializer returns the server winner, never forces
    /// its own proposal over an existing root.
    func createRoot(proposal: String) async throws -> ICloudCloudRoot
}

/// The root is outside the two clearable data zones. Only initialization of an
/// empty cloud library is automatic; resets and legacy adoption are separate.
struct ICloudRootCoordinator: Sendable {
    let repository: ICloudRecordRepository

    func ensureGeneration(
        using transport: any ICloudRootTransport,
        isCurrent: @escaping @Sendable () async throws -> Bool = { true }
    ) async throws -> String {
        do { return try await ensureVerifiedGeneration(using: transport, isCurrent: isCurrent) }
        catch let error as ICloudRootError {
            if error == .malformedRoot || error == .unsupportedVersion {
                guard try await isCurrent() else { throw CancellationError() }
                try repository.pause(reason: "invalidCloudRoot")
            }
            throw error
        }
    }

    private func ensureVerifiedGeneration(
        using transport: any ICloudRootTransport,
        isCurrent: @escaping @Sendable () async throws -> Bool
    ) async throws -> String {
        try Task.checkCancellation()
        guard try await isCurrent() else { throw CancellationError() }
        let binding = try await repository.rootBinding()
        guard try await isCurrent() else { throw CancellationError() }
        if binding.generation == nil, binding.hasPriorCloudState {
            try repository.pause(reason: "legacyCloudRoot")
            throw ICloudRootError.legacyCloudRequiresReview
        }
        let lookup = try await transport.lookupRoot()
        try Task.checkCancellation()
        guard try await isCurrent() else { throw CancellationError() }
        switch lookup {
        case .found(let root):
            try await repository.acceptCloudRoot(root, expectedGeneration: binding.generation)
            return root.generation
        case .missing(let hasExistingData):
            if binding.generation != nil {
                try repository.pause(reason: "cloudRootMissing")
                throw ICloudRootError.rootMissing
            }
            if hasExistingData {
                try repository.pause(reason: "legacyCloudRoot")
                throw ICloudRootError.legacyCloudRequiresReview
            }
            // Persist the proposal first: a crash, ambiguous network success or
            // a retry cannot silently create another epoch for the same attempt.
            let proposal = try await repository.proposeCloudGeneration()
            guard try await isCurrent() else { throw CancellationError() }
            let root = try await transport.createRoot(proposal: proposal)
            try Task.checkCancellation()
            guard try await isCurrent() else { throw CancellationError() }
            try await repository.acceptCloudRoot(root, expectedGeneration: binding.generation)
            return root.generation
        }
    }
}

enum ICloudGenerationRecordIdentity: Sendable, Equatable {
    case current(String), otherGeneration, legacy
}

enum ICloudGenerationIdentity {
    private static let prefix = "epoch-v1:"

    static func recordName(_ wireName: String, generation: String) throws -> String {
        try ICloudCloudRoot(generation: generation, phase: .ready).validate()
        guard !wireName.isEmpty else { throw ICloudRecordError.identityMismatch }
        return prefix + generation + ":" + wireName
    }

    static func classify(_ name: String, generation: String) throws -> ICloudGenerationRecordIdentity {
        try ICloudCloudRoot(generation: generation, phase: .ready).validate()
        guard name.hasPrefix(prefix) else { return .legacy }
        let components = name.dropFirst(prefix.count).split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard components.count == 2, !components[1].isEmpty else { throw ICloudRecordError.identityMismatch }
        let incoming = String(components[0])
        guard let uuid = UUID(uuidString: incoming), uuid.uuidString == incoming else { throw ICloudRecordError.identityMismatch }
        return incoming == generation ? .current(String(components[1])) : .otherGeneration
    }
}
