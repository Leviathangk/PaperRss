@preconcurrency import CloudKit
import Foundation
import GRDB

public struct ICloudNewLibraryReview: Sendable, Equatable {
    public let id: UUID
    public let localFeeds: Int
    public let localArticles: Int
    public let localStarredArticles: Int
    public let resumesApprovedOperation: Bool
}

enum ICloudNewLibraryReviewError: Error, Sendable, Equatable {
    case newLibraryConfirmationRequired, oldCloudRetentionRequired, staleReview, unavailableScope
}

struct ICloudNewLibraryContext: Sendable, Equatable {
    let root: ICloudCloudRoot
    let systemFingerprint: String
    let pauseReason: String?
    let operation: ICloudCloudResetOperation?
}

protocol ICloudNewLibraryObserving: Sendable {
    func readRoot(context: ICloudNewLibraryContext) async throws -> ICloudCloudResetRootSnapshot
}

/// Read-only review: no bootstrap, asset download, zone creation or root save.
struct ICloudNewLibraryCloudKitObserver: ICloudNewLibraryObserving {
    func readRoot(context: ICloudNewLibraryContext) async throws -> ICloudCloudResetRootSnapshot {
        guard ICloudSyncEngineDriver.isEntitled else { throw ICloudEngineError.notEntitled }
        let fingerprint = try await ICloudSyncEngineDriver.systemUserFingerprint()
        guard fingerprint == context.systemFingerprint else { throw ICloudRecordError.accountChanged }
        try Task.checkCancellation()
        let database = CKContainer(identifier: ICloudSyncEngineDriver.containerIdentifier).privateCloudDatabase
        let record = try await database.record(for: ICloudCloudRootCodec.recordID)
        try Task.checkCancellation()
        guard try await ICloudSyncEngineDriver.systemUserFingerprint() == fingerprint else { throw ICloudRecordError.accountChanged }
        return .init(root: try ICloudCloudRootCodec.decode(record), systemFields: ICloudRecordCodec.systemFields(record), systemFingerprint: fingerprint)
    }
}

extension ICloudRecordRepository {
    func newLibraryContext() async throws -> ICloudNewLibraryContext {
        try await database.readAsync { db in
            try self.requireScope(in: db, permitsPause: true)
            guard try AccountRecord.fetchOne(db, key: self.accountID)?.isEnabled == true,
                  let row = try Row.fetchOne(db, sql: "SELECT * FROM icloud_sync_scope WHERE account_id=?", arguments: [self.accountID]),
                  let generation: String = row["cloud_generation"], let fingerprint: String = row["user_fingerprint"] else {
                throw ICloudNewLibraryReviewError.unavailableScope
            }
            let root = ICloudCloudRoot(generation: generation, phase: .ready, protocolVersion: row["cloud_protocol_version"])
            try root.validate()
            let data: Data? = row["cloud_reset_operation"]
            let operation = try data.map(ICloudCloudResetOperation.decode)
            let pauseReason: String? = row["pause_reason"]
            if let operation {
                guard operation.approval.previousRoot == root,
                      operation.approval.systemFingerprint == fingerprint,
                      operation.approval.previousDataDisposition == .preserve,
                      operation.approval.replacementProtocolVersion == 3,
                      pauseReason == (operation.stage == .cloudReady ? "cloudResetReview" : "cloudResetRequested") else {
                    throw ICloudNewLibraryReviewError.unavailableScope
                }
            }
            return .init(root: root, systemFingerprint: fingerprint, pauseReason: pauseReason, operation: operation)
        }
    }
}

/// Concrete approval to prepare an empty isolated cloud library while keeping
/// previous cloud zones. Local archival/adoption is a separate reviewed flow.
actor ICloudNewLibraryReviewer {
    private let repository: ICloudRecordRepository
    private let lifetime: Duration
    private var preparation: UUID?
    private var review: (value: ICloudNewLibraryReview, context: ICloudNewLibraryContext,
                         approval: ICloudCloudResetApproval, expires: ContinuousClock.Instant)?
    init(repository: ICloudRecordRepository, lifetime: Duration = .seconds(600)) {
        self.repository = repository; self.lifetime = lifetime
    }

    func prepare(using observer: any ICloudNewLibraryObserving) async throws -> ICloudNewLibraryReview {
        guard preparation == nil else { throw ICloudCloudResetError.operationInProgress }
        let id = UUID(); preparation = id; review = nil
        defer { if preparation == id { preparation = nil } }
        let context = try await repository.newLibraryContext()
        let snapshot = try await observer.readRoot(context: context)
        try Task.checkCancellation()
        try snapshot.root.validate()
        let afterRead = try await repository.newLibraryContext()
        guard preparation == id, snapshot.systemFingerprint == context.systemFingerprint,
              context == afterRead else { throw ICloudNewLibraryReviewError.staleReview }
        let approval: ICloudCloudResetApproval
        if let operation = context.operation {
            approval = operation.approval
            guard [approval.previousRoot, approval.resettingRoot, approval.replacementRoot].contains(snapshot.root) else {
                throw ICloudCloudResetError.unexpectedRoot
            }
        } else {
            guard snapshot.root == context.root else { throw ICloudCloudResetError.unexpectedRoot }
            approval = .init(operationID: UUID().uuidString, previousGeneration: context.root.generation,
                replacementGeneration: UUID().uuidString, systemFingerprint: context.systemFingerprint,
                previousProtocolVersion: context.root.protocolVersion, replacementProtocolVersion: 3, previousDataDisposition: .preserve)
        }
        try approval.validate()
        let local = try await repository.recoveryReview()
        let afterCounts = try await repository.newLibraryContext()
        guard preparation == id, context == afterCounts else { throw ICloudNewLibraryReviewError.staleReview }
        let value = ICloudNewLibraryReview(id: id, localFeeds: local.feeds, localArticles: local.articles,
            localStarredArticles: local.starredArticles, resumesApprovedOperation: context.operation != nil)
        review = (value, context, approval, ContinuousClock.now.advanced(by: lifetime))
        return value
    }

    func approve(id: UUID, newLibraryConfirmed: Bool, oldCloudRetentionConfirmed: Bool) async throws -> ICloudCloudResetOperation {
        guard let review, review.value.id == id, ContinuousClock.now < review.expires,
              review.context == (try await repository.newLibraryContext()) else { throw ICloudNewLibraryReviewError.staleReview }
        guard self.review?.value.id == id, ContinuousClock.now < review.expires else { throw ICloudNewLibraryReviewError.staleReview }
        if let existing = review.context.operation {
            self.review = nil
            return existing // Preserve the original explicit approval and operation UUID.
        }
        guard newLibraryConfirmed else { throw ICloudNewLibraryReviewError.newLibraryConfirmationRequired }
        guard oldCloudRetentionConfirmed else { throw ICloudNewLibraryReviewError.oldCloudRetentionRequired }
        try Task.checkCancellation()
        let operation = try await repository.beginCloudReset(review.approval)
        self.review = nil
        return operation
    }
    func discard(id: UUID? = nil) {
        if id == nil || review?.value.id == id { review = nil }
        if id == nil || preparation == id { preparation = nil }
    }
}
