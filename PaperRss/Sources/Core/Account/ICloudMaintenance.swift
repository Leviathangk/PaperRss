import Foundation

/// Counts come from a paginated cloud query, never from the local wire cache.
/// A query is not a transaction: another device can edit records during a scan.
public struct ICloudCloudInventory: Sendable, Equatable {
    public let scannedAt: Date
    public let isComplete: Bool
    public let reachedSafetyLimit: Bool
    public let recordCount: Int
    public let otherGenerationRecords: Int
    public let otherGenerationZones: Int
    public let feeds: Int
    public let folders: Int
    public let relationships: Int
    public let readStateRecords: Int
    public let starredStateRecords: Int
    public let starredBodies: Int
    public let unreadBodies: Int
    public let readBodies: Int
    public let orphanedBodies: Int
    public let bodiesWithIncompleteStatus: Int
    public let contentTombstones: Int
    public let cleanupPreview: ICloudCleanupPreview?
}

/// Preview only. No record deletion or change to local reading history.
/// Retention and destructive execution require the separately reviewed policy.
public struct ICloudCleanupPreview: Sendable, Equatable {
    public let removableBodies: Int
    public let staleStateRecords: Int
    public let protectedArticles: Int
    public let proposedRecordCount: Int
    public let hasUnresolvedLocalChanges: Bool
}

struct ICloudCloudRecordMetadata: Sendable {
    let envelope: ICloudRecordEnvelope
    let creationDate: Date?
    let modificationDate: Date?
    /// Private execution metadata. Inventory UI receives only aggregate counts.
    let systemFields: Data?
    let changeTag: String?

    init(envelope: ICloudRecordEnvelope, creationDate: Date?, modificationDate: Date? = nil,
         systemFields: Data? = nil, changeTag: String? = nil) {
        self.envelope = envelope
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.systemFields = systemFields; self.changeTag = changeTag
    }
}

struct ICloudInventoryPage: Sendable {
    let records: [ICloudCloudRecordMetadata]
    let cursor: Data?
    let envelopeBytes: Int
    var otherGenerationRecords: Int = 0
    var otherGenerationZones: Int = 0
}

protocol ICloudInventoryPageFetching: Sendable {
    func inventoryPage(zone: ICloudRecordZone, cursor: Data?, limit: Int) async throws -> ICloudInventoryPage
}

struct ICloudMaintenanceProtection: Sendable {
    var recordNames: Set<String> = []
    var hasUnresolvedChanges = false
}

enum ICloudInventoryError: Error, Sendable, Equatable {
    case alreadyScanning, malformedPage
}

struct ICloudInventoryBudget: Sendable {
    var duration: Duration = .seconds(10)
    var pageLimit = 50
    var recordLimit = 20_000
    var envelopeByteLimit = 16 * 1024 * 1024
}

/// A cursor is retained only in memory. Continuing a time-limited scan does not
/// repeat its first pages. Record and byte limits bound the entire session.
actor ICloudInventoryScanner {
    private let source: any ICloudInventoryPageFetching
    private var records: [String: ICloudCloudRecordMetadata] = [:]
    private var zoneIndex = 0
    private var cursor: Data?
    private var envelopeBytes = 0
    private var fetchedRecords = 0
    private var otherGenerationRecords = 0
    private var otherGenerationZones = 0
    private var isScanning = false
    private var reachedSafetyLimit = false
    private var isCancelled = false

    init(source: any ICloudInventoryPageFetching) { self.source = source }

    func cancel() { isCancelled = true }

    func scan(budget: ICloudInventoryBudget = .init()) async throws -> [ICloudCloudRecordMetadata] {
        guard !isScanning else { throw ICloudInventoryError.alreadyScanning }
        guard !isCancelled else { throw CancellationError() }
        guard budget.duration > .zero, budget.pageLimit > 0,
              budget.recordLimit > 0, budget.envelopeByteLimit > 0 else {
            throw ICloudInventoryError.malformedPage
        }
        isScanning = true
        defer { isScanning = false }
        let deadline = ContinuousClock.now.advanced(by: budget.duration)
        var pages = 0
        while zoneIndex < ICloudRecordZone.allCases.count, !reachedSafetyLimit,
              pages < budget.pageLimit, ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard !isCancelled else { throw CancellationError() }
            let remaining = budget.recordLimit - fetchedRecords
            guard remaining > 0, envelopeBytes < budget.envelopeByteLimit else {
                reachedSafetyLimit = true
                break
            }
            let zone = ICloudRecordZone.allCases[zoneIndex]
            let requested = min(200, remaining)
            let page = try await source.inventoryPage(zone: zone, cursor: cursor, limit: requested)
            try Task.checkCancellation()
            guard !isCancelled else { throw CancellationError() }
            guard page.otherGenerationRecords >= 0, page.otherGenerationZones >= 0,
                  page.records.count <= requested, page.otherGenerationRecords <= requested - page.records.count,
                  page.envelopeBytes >= 0,
                  page.cursor == nil || page.cursor != cursor,
                  page.records.allSatisfy({ $0.envelope.zone == zone }) else {
                throw ICloudInventoryError.malformedPage
            }
            // Do not retain an oversized page, nor skip it by advancing the cursor.
            guard page.envelopeBytes <= budget.envelopeByteLimit - envelopeBytes else {
                reachedSafetyLimit = true
                break
            }
            let remainingBytes = budget.envelopeByteLimit - envelopeBytes
            var pageBytes = page.envelopeBytes
            // Conditional system fields are additional to the source's wire
            // envelopes. Check by subtraction so even an oversized declaration
            // cannot overflow or bypass the shared session memory ceiling.
            for record in page.records {
                let fields = record.systemFields?.count ?? 0
                guard fields <= remainingBytes - pageBytes else { reachedSafetyLimit = true; break }
                pageBytes += fields
                let tag = record.changeTag?.utf8.count ?? 0
                guard tag <= remainingBytes - pageBytes else { reachedSafetyLimit = true; break }
                pageBytes += tag
            }
            guard !reachedSafetyLimit else { break }
            for record in page.records { try record.envelope.validate() }
            for record in page.records {
                records[record.envelope.recordName] = record
            }
            envelopeBytes += pageBytes
            fetchedRecords += page.records.count + page.otherGenerationRecords
            otherGenerationRecords += page.otherGenerationRecords
            otherGenerationZones = max(otherGenerationZones, page.otherGenerationZones)
            cursor = page.cursor
            if cursor == nil { zoneIndex += 1 }
            pages += 1
        }
        return Array(records.values)
    }

    var isComplete: Bool { zoneIndex == ICloudRecordZone.allCases.count && !reachedSafetyLimit }
    var didReachSafetyLimit: Bool { reachedSafetyLimit }
    var foreignRecordCount: Int { otherGenerationRecords }
    var foreignZoneCount: Int { otherGenerationZones }
}

enum ICloudMaintenancePlanner {
    static let proposedRetention: TimeInterval = 183 * 24 * 60 * 60
    static let proposedRecordLimit = 400

    private struct Article {
        var read: ICloudCloudRecordMetadata?
        var starred: ICloudCloudRecordMetadata?
        var content: ICloudCloudRecordMetadata?
        var isRead: Bool? { flag(read) }
        var isStarred: Bool? { flag(starred) }
        var hasBody: Bool {
            if case .text = content?.envelope.fields["payload_hash"]?.value { return true }
            return false
        }
        private func flag(_ record: ICloudCloudRecordMetadata?) -> Bool? {
            if case .flag(let value) = record?.envelope.fields["value"]?.value { return value }
            return nil
        }
    }

    static func inventory(
        records: [ICloudCloudRecordMetadata], isComplete: Bool, reachedSafetyLimit: Bool,
        syncUnreadContent: Bool, protection: ICloudMaintenanceProtection,
        now: Date = Date(), limit: Int = proposedRecordLimit, otherGenerationRecords: Int = 0, otherGenerationZones: Int = 0
    ) -> ICloudCloudInventory {
        var articles: [String: Article] = [:]
        var feeds = 0, folders = 0, relationships = 0, readStates = 0, starStates = 0
        for record in records {
            let envelope = record.envelope
            switch envelope.kind {
            case .feed: feeds += 1
            case .folder: folders += 1
            case .membership: relationships += 1
            case .read, .starred, .content:
                let key = articleKey(envelope.recordName)
                var article = articles[key] ?? Article()
                switch envelope.kind {
                case .read: article.read = record; readStates += 1
                case .starred: article.starred = record; starStates += 1
                default: article.content = record
                }
                articles[key] = article
            case .settings, .retention, .retentionPolicy, .retentionQuota: break
            }
        }
        var starred = 0, unread = 0, read = 0, orphans = 0, incomplete = 0, tombstones = 0
        var bodiesToRemove = 0, staleStates = 0, protected = 0, proposed = 0
        let protectedKeys = Set(protection.recordNames.map(articleKey))
        let cutoff = now.addingTimeInterval(-proposedRetention)
        // Stable order makes a bounded preview reproducible across page orders.
        for key in articles.keys.sorted() {
            let article = articles[key]!
            if article.hasBody {
                if article.isStarred == true { starred += 1 }
                else if article.isStarred == false, let isRead = article.isRead {
                    if isRead { read += 1 } else { unread += 1 }
                } else if isComplete, article.read == nil, article.starred == nil { orphans += 1 }
                else { incomplete += 1 }
            } else if article.content != nil { tombstones += 1 }
            guard isComplete else { continue }
            let feedURL = (article.content ?? article.read ?? article.starred)?.envelope.feedURL
            let feedName = feedURL.flatMap(URL.init(string:))
                .flatMap { try? ICloudSyncIdentity.feedRecordName(feedURL: $0) }
            if protection.hasUnresolvedChanges || protectedKeys.contains(key) ||
                feedName.map(protection.recordNames.contains) == true {
                protected += 1
                continue
            }
            let knownUnstarred = article.isStarred == false && article.isRead != nil
            let removableBody = article.hasBody &&
                ((article.read == nil && article.starred == nil) ||
                 (knownUnstarred && (article.isRead == true || !syncUnreadContent)))
            if removableBody {
                bodiesToRemove += 1
                if proposed < max(0, limit) { proposed += 1 }
            }
            // Keep both state records together. Missing dates, a newly changed
            // pair, unknown state and eligible unread content remain protected.
            if knownUnstarred, article.isRead == true || !syncUnreadContent,
               let readDate = article.read?.creationDate, let starDate = article.starred?.creationDate,
               let readModified = article.read?.modificationDate, let starModified = article.starred?.modificationDate,
               readDate < cutoff, starDate < cutoff, readModified < cutoff, starModified < cutoff {
                staleStates += 2
                if max(0, limit) - proposed >= 2 { proposed += 2 }
            }
        }
        return .init(scannedAt: now, isComplete: isComplete, reachedSafetyLimit: reachedSafetyLimit,
            recordCount: records.count + otherGenerationRecords, otherGenerationRecords: otherGenerationRecords,
            otherGenerationZones: otherGenerationZones,
            feeds: feeds, folders: folders, relationships: relationships,
            readStateRecords: readStates, starredStateRecords: starStates,
            starredBodies: starred, unreadBodies: unread, readBodies: read, orphanedBodies: orphans,
            bodiesWithIncompleteStatus: incomplete, contentTombstones: tombstones,
            cleanupPreview: isComplete ? .init(removableBodies: bodiesToRemove, staleStateRecords: staleStates,
                protectedArticles: protected, proposedRecordCount: proposed,
                hasUnresolvedLocalChanges: protection.hasUnresolvedChanges) : nil)
    }

    static func articleKey(_ name: String) -> String {
        for prefix in ["read-v1:", "starred-v1:", "content-v1:"] where name.hasPrefix(prefix) {
            return String(name.dropFirst(prefix.count))
        }
        return name
    }
}
