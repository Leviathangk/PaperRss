import Foundation

struct ICloudRetentionDiscoveryBinding: Sendable, Equatable {
    let generation: String
    let systemFingerprint: String
    let syncUnreadContent: Bool
    init(_ context: ICloudRetentionReviewContext) {
        generation = context.generation; systemFingerprint = context.systemFingerprint
        syncUnreadContent = context.syncUnreadContent
    }
}

struct ICloudRetentionDiscoveryBudget: Sendable {
    var duration: Duration = .seconds(10)
    var pageLimit = 10
    var recordLimit = 2_000
    var articleLimit = 400
    var envelopeByteLimit = 16 * 1_024 * 1_024
}

/// A discovery cursor is advisory and only lives in this provider session.
/// Each pass has bounded pages/bytes; the entire cloud library need not fit in
/// the statistics cache. Retained candidates contain hashed addresses only.
actor ICloudRetentionDiscoveryScanner {
    private let source: any ICloudInventoryPageFetching
    private var cursor: Data?
    private var backlog: [String] = []
    private var exhausted = false
    private var scanning = false
    private var cancelled = false
    init(source: any ICloudInventoryPageFetching) { self.source = source }
    func cancel() { cancelled = true }

    func scan(protection: ICloudMaintenanceProtection, now: Date,
              budget: ICloudRetentionDiscoveryBudget = .init()) async throws -> [String] {
        guard !cancelled else { throw CancellationError() }
        guard !scanning else { throw ICloudInventoryError.alreadyScanning }
        guard !protection.hasUnresolvedChanges else { throw ICloudRetentionError.unresolvedChanges }
        guard budget.duration > .zero, (1...50).contains(budget.pageLimit),
              (1...20_000).contains(budget.recordLimit), (1...400).contains(budget.articleLimit),
              (1...16 * 1_024 * 1_024).contains(budget.envelopeByteLimit),
              now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 >= 0 else {
            throw ICloudInventoryError.malformedPage
        }
        scanning = true
        defer { scanning = false }
        // An explicit new review can begin another cycle after the last one;
        // no timer discovers/approves future targets on the user's behalf.
        if exhausted && backlog.isEmpty { exhausted = false; cursor = nil }
        let protectedKeys = Set(protection.recordNames.map(ICloudMaintenancePlanner.articleKey))
        var selected = Set(backlog.filter { !protectedKeys.contains(String($0.dropFirst("article-v1:".count))) })
        backlog = []
        var returned = false
        defer {
            // A later failed page must not lose addresses from earlier valid
            // pages after their cursor has already advanced.
            if !returned { backlog = selected.sorted() }
        }
        let cutoff = now.addingTimeInterval(-ICloudMaintenancePlanner.proposedRetention)
        let deadline = ContinuousClock.now.advanced(by: budget.duration)
        var pages = 0, records = 0, bytes = 0
        while !exhausted, selected.count < budget.articleLimit, pages < budget.pageLimit,
              records < budget.recordLimit, ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard !cancelled else { throw CancellationError() }
            let limit = min(100, budget.recordLimit - records)
            let page = try await source.inventoryPage(zone: .articles, cursor: cursor, limit: limit)
            try Task.checkCancellation()
            guard !cancelled else { throw CancellationError() }
            guard page.records.count <= limit, page.otherGenerationRecords >= 0,
                  page.otherGenerationRecords <= limit - page.records.count, page.otherGenerationZones >= 0,
                  page.envelopeBytes >= 0, page.envelopeBytes <= budget.envelopeByteLimit - bytes,
                  (page.cursor?.count ?? 0) <= 64 * 1_024,
                  page.cursor == nil || page.cursor != cursor,
                  page.records.allSatisfy({ $0.envelope.zone == .articles }),
                  Set(page.records.map(\.envelope.recordName)).count == page.records.count else {
                throw ICloudInventoryError.malformedPage
            }
            var pageBytes = page.envelopeBytes, hints: Set<String> = []
            let cursorBytes = page.cursor?.count ?? 0
            guard cursorBytes <= budget.envelopeByteLimit - bytes - pageBytes else { throw ICloudInventoryError.malformedPage }
            pageBytes += cursorBytes
            for record in page.records {
                try record.envelope.validate()
                let fields = record.systemFields?.count ?? 0, tag = record.changeTag?.utf8.count ?? 0
                guard fields <= budget.envelopeByteLimit - bytes - pageBytes else { throw ICloudInventoryError.malformedPage }
                pageBytes += fields
                guard tag <= budget.envelopeByteLimit - bytes - pageBytes else { throw ICloudInventoryError.malformedPage }
                pageBytes += tag
                let envelope = record.envelope
                let feedName = envelope.feedRecordName ?? envelope.feedURL.flatMap(URL.init(string:))
                    .flatMap { try? ICloudSyncIdentity.feedRecordName(feedURL: $0) }
                guard let hint = Self.hint(record, cutoff: cutoff), !protectedKeys.contains(hint),
                      !protection.recordNames.contains(feedName ?? "") else { continue }
                hints.insert("article-v1:" + hint)
            }
            // Advance only after the entire page is valid. Query absence is
            // never treated as a point-read unknownItem proof.
            cursor = page.cursor; exhausted = cursor == nil
            records += page.records.count + page.otherGenerationRecords
            bytes += pageBytes; pages += 1
            selected.formUnion(hints)
        }
        let ordered = selected.sorted()
        backlog = Array(ordered.dropFirst(budget.articleLimit))
        returned = true
        return Array(ordered.prefix(budget.articleLimit))
    }

    private static func hint(_ record: ICloudCloudRecordMetadata, cutoff: Date) -> String? {
        let envelope = record.envelope
        switch envelope.kind {
        case .content:
            guard case .text = envelope.fields["payload_hash"]?.value else { return nil }
        case .read, .starred:
            guard case .flag(let value) = envelope.fields["value"]?.value,
                  value == (envelope.kind == .read),
                  let created = record.creationDate, let modified = record.modificationDate,
                  created.timeIntervalSince1970.isFinite, created.timeIntervalSince1970 >= 0,
                  modified.timeIntervalSince1970.isFinite, modified >= created,
                  created < cutoff, modified < cutoff else { return nil }
        default: return nil
        }
        return ICloudMaintenancePlanner.articleKey(envelope.recordName)
    }
}
