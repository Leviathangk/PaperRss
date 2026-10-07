import Foundation
import GRDB

/// Local selection data. Credential-bearing addresses are never returned, and
/// GUIDs/article text are absent. Other addresses are shown only when the user
/// opens link details, so the exact selected links can be reviewed locally.
public struct ICloudCopySourceCatalog: Sendable {
    public struct Feed: Identifiable, Sendable {
        public enum Block: Sendable, Equatable { case credentials, invalidURL, duplicateIdentity }
        public let id, title: String
        public let address, siteAddress: String?
        public let requiresLinkReview: Bool
        public let blocked: Block?
    }
    public struct Folder: Identifiable, Sendable {
        public let id, name: String
        public let isDuplicateName: Bool
    }
    public let feeds: [Feed]
    public let folders: [Folder]
    public let sourceIsEnabled: Bool
    public let sourceIsArchive: Bool
    let sourceAccountID: String
    let database: LibraryDatabase
    fileprivate let feedSignatures: [String: FeedSignature]
    fileprivate let folderNames: [String: String]

    fileprivate struct FeedSignature: Sendable, Equatable {
        let title, address: String
        let siteAddress: String?
    }
}

public struct ICloudCopySelection: Sendable, Equatable {
    public let feedIDs, folderIDs, reviewedLinkIDs: Set<String>
    public let includeReliableArticles: Bool
    public init(feedIDs: Set<String>, folderIDs: Set<String>, includeReliableArticles: Bool, reviewedLinkIDs: Set<String> = []) {
        self.feedIDs = feedIDs; self.folderIDs = folderIDs
        self.includeReliableArticles = includeReliableArticles; self.reviewedLinkIDs = reviewedLinkIDs
    }
}

public struct ICloudCopyCounts: Sendable, Equatable {
    public let feeds, folders, relationships, articles, rssBodies, omittedRSSBodies: Int
    public let skippedFeeds, skippedFolders, skippedArticles: Int
    init(_ value: ICloudLocalCopyRepository.Counts) {
        feeds = value.feeds; folders = value.folders; relationships = value.relationships
        articles = value.articles; rssBodies = value.rssBodies; omittedRSSBodies = value.omittedRSSBodies
        skippedFeeds = value.skippedFeeds; skippedFolders = value.skippedFolders; skippedArticles = value.skippedArticles
    }
    public var hasCopies: Bool { feeds > 0 || folders > 0 || articles > 0 }
}

/// Opaque review token; system fingerprint/generation and source values stay in
/// Core. Preparing this review never copies source data into the target account.
public struct ICloudCopyReview: Identifiable, Sendable {
    public let id: UUID
    public let counts: ICloudCopyCounts
    public let preparedAt: Date
}

public struct ICloudCopyResult: Sendable {
    public let counts: ICloudCopyCounts
    /// A committed local copy must not be reported as failed/retried just because
    /// announcing pending changes encountered a network error afterwards.
    public let syncWarning: String?
}

extension ICloudLocalCopyRepository {
    func preflightCatalog(_ catalog: ICloudCopySourceCatalog, selection: Selection) async throws {
        try Task.checkCancellation()
        try await database.readAsync { db in
            guard !selection.feedIDs.isEmpty || !selection.folderIDs.isEmpty,
                  selection.feedIDs.count + selection.folderIDs.count <= 500,
                  selection.reviewedLinkIDs.isSubset(of: selection.feedIDs),
                  try Self.copySource(accountID: selection.sourceAccountID, in: db) != nil else {
                throw ICloudLocalCopyError.invalidSelection
            }
            try self.validateCatalog(catalog, selection: selection, in: db)
        }
    }

    func sourceCatalog(accountID: String) async throws -> ICloudCopySourceCatalog {
        try Task.checkCancellation()
        return try await database.readAsync { db in
            guard let source = try Self.copySource(accountID: accountID, in: db) else {
                throw ICloudLocalCopyError.invalidSelection
            }
            let feeds = try FeedRecord.filter(Column("account_id") == accountID && Column("is_deleted") == false)
                .order(Column("sort_order"), Column("id")).fetchAll(db)
            let folders = try FolderRecord.filter(Column("account_id") == accountID && Column("is_deleted") == false)
                .order(Column("sort_order"), Column("id")).fetchAll(db)
            let links = Dictionary(uniqueKeysWithValues: feeds.map { ($0.id, ICloudSyncIdentity.FeedLinkReview($0.feedURL)) })
            let groups = Dictionary(grouping: links.values.compactMap(\.recordName), by: { $0 })
            let folderGroups = Dictionary(grouping: folders.map(\.name), by: { $0 })
            let rows: [ICloudCopySourceCatalog.Feed] = feeds.map { feed in
                let link = links[feed.id]!, site = feed.siteURL.map(ICloudSyncIdentity.FeedLinkReview.init)
                let blocked: ICloudCopySourceCatalog.Feed.Block?
                if link.hasCredentials || site?.hasCredentials == true { blocked = .credentials }
                else if link.isUnverifiable || site?.isUnverifiable == true { blocked = .invalidURL }
                else if groups[link.recordName!]?.count != 1 { blocked = .duplicateIdentity }
                else { blocked = nil }
                return .init(id: feed.id, title: feed.title,
                    address: blocked == nil ? feed.feedURL : nil,
                    siteAddress: blocked == nil ? feed.siteURL : nil,
                    requiresLinkReview: link.needsReview || site?.needsReview == true, blocked: blocked)
            }
            let blockedIDs = Set(rows.filter { $0.blocked != nil }.map(\.id))
            return .init(feeds: rows, folders: folders.map {
                .init(id: $0.id, name: $0.name, isDuplicateName: folderGroups[$0.name]?.count != 1)
            }, sourceIsEnabled: source.isEnabled, sourceIsArchive: source.isArchived,
                sourceAccountID: source.id, database: self.database,
                feedSignatures: Dictionary(uniqueKeysWithValues: feeds.filter { !blockedIDs.contains($0.id) }.map {
                    ($0.id, .init(title: $0.title, address: $0.feedURL, siteAddress: $0.siteURL))
                }), folderNames: Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.name) }))
        }
    }

    /// Bind the visible selection to the exact local links/names reviewed in the
    /// catalog. A link changing before plan preparation needs fresh review too.
    func validateCatalog(_ catalog: ICloudCopySourceCatalog, selection: Selection, in db: Database) throws {
        guard catalog.database === database, catalog.sourceAccountID == selection.sourceAccountID,
              let source = try Self.copySource(accountID: catalog.sourceAccountID, in: db),
              source.isArchived == catalog.sourceIsArchive else {
            throw ICloudLocalCopyError.stalePlan
        }
        for id in selection.feedIDs {
            guard let expected = catalog.feedSignatures[id], let current = try FeedRecord.fetchOne(db, key: id),
                  !current.isDeleted, current.accountID == catalog.sourceAccountID,
                  expected == .init(title: current.title, address: current.feedURL, siteAddress: current.siteURL)
            else { throw ICloudLocalCopyError.stalePlan }
        }
        for id in selection.folderIDs {
            guard let expected = catalog.folderNames[id], let current = try FolderRecord.fetchOne(db, key: id),
                  !current.isDeleted, current.accountID == catalog.sourceAccountID, current.name == expected
            else { throw ICloudLocalCopyError.stalePlan }
        }
    }

    /// Active or ordinarily disabled cloud/server accounts are never copy
    /// sources. Only an explicitly frozen archive joins the existing local path.
    static func copySource(accountID: String, in db: Database) throws -> AccountRecord? {
        guard let source = try AccountRecord.fetchOne(db, key: accountID) else { return nil }
        if source.type == AccountType.local.rawValue, !source.isArchived { return source }
        guard source.type == AccountType.iCloud.rawValue, source.isArchived, !source.isEnabled,
              let scope = try Row.fetchOne(db, sql: "SELECT capture_enabled, suppress_capture, pause_reason FROM icloud_sync_scope WHERE account_id = ?", arguments: [accountID]),
              !(scope["capture_enabled"] as Bool), scope["suppress_capture"] as Bool,
              let pause: String = scope["pause_reason"], !pause.isEmpty else { return nil }
        return source
    }
}
