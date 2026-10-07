import Darwin
import Foundation

/// Runs only a durably approved reset. Construction is inert. Normal sync
/// cannot call this through the provider or automatic engine entry points.
actor ICloudCloudResetCoordinator {
    private let repository: ICloudRecordRepository
    private var running: (id: UUID, operationID: String, task: Task<ICloudCloudResetOperation, any Error>)?
    private var lifecycle = 0

    init(repository: ICloudRecordRepository) { self.repository = repository }

    func resume(
        operationID: String, using transport: any ICloudCloudResetTransport,
        isCurrent: @escaping @Sendable () async throws -> Bool = { true }
    ) async throws -> ICloudCloudResetOperation {
        if let current = running {
            guard current.operationID == operationID else { throw ICloudCloudResetError.operationInProgress }
            return try await current.task.value
        }
        let id = UUID(), generation = lifecycle
        let task = Task {
            try await self.perform(operationID: operationID, transport: transport,
                                   lifecycle: generation, isCurrent: isCurrent)
        }
        running = (id, operationID, task)
        defer { if running?.id == id { running = nil } }
        return try await task.value
    }

    func stop() {
        lifecycle &+= 1
        running?.task.cancel()
        running = nil
    }

    private func check(_ expected: ICloudCloudResetOperation, lifecycle: Int,
                       isCurrent: @Sendable () async throws -> Bool) async throws {
        try Task.checkCancellation()
        guard lifecycle == self.lifecycle, try await isCurrent() else { throw CancellationError() }
        let current = try await repository.cloudResetOperation(id: expected.approval.operationID)
        try Task.checkCancellation()
        guard lifecycle == self.lifecycle else { throw CancellationError() }
        guard current == expected else { throw ICloudCloudResetError.operationChanged }
    }

    private func perform(
        operationID: String, transport: any ICloudCloudResetTransport,
        lifecycle: Int, isCurrent: @Sendable () async throws -> Bool
    ) async throws -> ICloudCloudResetOperation {
        var operation = try await repository.cloudResetOperation(id: operationID)
        try await check(operation, lifecycle: lifecycle, isCurrent: isCurrent)
        if operation.stage == .cloudReady { return operation }
        let lease = try ICloudCloudResetLease(repository: repository)
        defer { withExtendedLifetime(lease) {} }
        while true {
            try await check(operation, lifecycle: lifecycle, isCurrent: isCurrent)
            let snapshot = try await transport.readRoot()
            try await check(operation, lifecycle: lifecycle, isCurrent: isCurrent)
            try snapshot.root.validate()
            guard snapshot.systemFingerprint == operation.approval.systemFingerprint else {
                throw ICloudRecordError.accountChanged
            }
            let previous = operation.approval.previousGeneration
            let replacement = operation.approval.replacementGeneration
            if snapshot.root == operation.approval.replacementRoot {
                // An ambiguous final save or restored old local checkpoint must
                // never replay deletions against a library already in use.
                return try await repository.markCloudResetReady(operation, observed: snapshot.root)
            }
            if operation.stage == .prepared {
                if snapshot.root == operation.approval.previousRoot {
                    try await transport.writeRoot(operation.approval.resettingRoot, replacing: snapshot)
                    try await check(operation, lifecycle: lifecycle, isCurrent: isCurrent)
                } else if snapshot.root != operation.approval.resettingRoot {
                    throw ICloudCloudResetError.unexpectedRoot
                }
                operation = try await repository.advanceCloudReset(operation, to: .rootPublished)
                continue
            }
            guard snapshot.root == operation.approval.resettingRoot else {
                throw ICloudCloudResetError.unexpectedRoot
            }
            let next: ICloudCloudResetOperation.Stage
            switch operation.stage {
            case .rootPublished:
                try await transport.createZone(.library, generation: replacement)
                next = .libraryCreated
            case .libraryCreated:
                try await transport.createZone(.articles, generation: replacement)
                next = .articlesCreated
            case .articlesCreated:
                if operation.approval.previousDataDisposition == .preserve {
                    next = .previousRetained
                } else {
                    try await transport.deleteZone(.library, generation: previous)
                    next = .libraryDeleted
                }
            case .libraryDeleted:
                try await transport.deleteZone(.articles, generation: previous)
                next = .articlesDeleted
            case .articlesDeleted, .previousRetained:
                let ready = operation.approval.replacementRoot
                try await transport.writeRoot(ready, replacing: snapshot)
                try await check(operation, lifecycle: lifecycle, isCurrent: isCurrent)
                return try await repository.markCloudResetReady(operation, observed: ready)
            case .prepared, .cloudReady:
                throw ICloudCloudResetError.invalidOperation
            }
            try await check(operation, lifecycle: lifecycle, isCurrent: isCurrent)
            operation = try await repository.advanceCloudReset(operation, to: next)
        }
    }
}

/// The kernel releases this lock after crashes. A live executor holds it across
/// all awaits, so another local executor cannot steal it via an elapsed timeout.
/// Server requests may outlive the process; physical epoch IDs fence those.
final class ICloudCloudResetLease {
    private let descriptor: Int32

    init(repository: ICloudRecordRepository) throws {
        let suffix = ICloudSyncIdentity.digest([repository.accountID])
        let path = repository.database.databasePath + ".cloud-reset-" + suffix + ".lock"
        let fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ICloudCloudResetError.invalidOperation }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_uid == getuid(), metadata.st_nlink == 1,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), metadata.st_size == 0,
              metadata.st_mode & mode_t(0o077) == 0 else {
            close(fd)
            throw ICloudCloudResetError.invalidOperation
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw ICloudCloudResetError.operationInProgress
        }
        descriptor = fd
    }
    deinit { close(descriptor) }
}
