import Foundation
import GRDB

public struct ICloudArchiveQuery: Sendable, Equatable {
    public enum Section: String, Sendable { case articles, ai }
    public let section: Section
    public let feedID, folderID: String?
    public let starredOnly: Bool
    public let search: String
    public let page: Int
    public init(section: Section = .articles, feedID: String? = nil, folderID: String? = nil,
                starredOnly: Bool = false, search: String = "", page: Int = 0) {
        self.section = section; self.feedID = feedID; self.folderID = folderID
        self.starredOnly = starredOnly; self.search = search; self.page = page
    }
}

public struct ICloudArchiveCatalog: Sendable {
    public struct Collection: Identifiable, Sendable { public let id, name: String }
    public let feeds, folders: [Collection]
}

/// No body, image address, GUID, cloud identity or AI content in list rows.
public struct ICloudArchiveListItem: Identifiable, Sendable {
    public let id, title, source: String
    public let isRead, isStarred: Bool
    public let date: Date?
}

public struct ICloudArchivePage: Sendable {
    public let items: [ICloudArchiveListItem]
    public let hasMore: Bool
}

public struct ICloudArchiveDetail: Sendable {
    public let id, title: String
    public let author: String?
    public let originalURL: URL?
    public let document: ReaderDocument?
    public let localAI: [ICloudArchiveAIResult]
}

public struct ICloudArchiveAIResult: Identifiable, Sendable {
    public let id, kind, targetLanguage, content: String
    public let selectionText: String?
    public let isComplete: Bool
    public let updatedAt: Double
    init(_ record: AIArtifactRecord) {
        id = record.id; kind = record.kind; targetLanguage = record.targetLanguage
        selectionText = record.selectionText; isComplete = record.isComplete; updatedAt = record.updatedAt
        if !record.content.isEmpty { content = record.content }
        else if let json = record.segmentsJSON, let segments = try? JSONDecoder().decode([BilingualSegment].self, from: Data(json.utf8)) {
            content = segments.map { "\($0.original)\n\($0.translation)" }.joined(separator: "\n\n")
        } else { content = record.segmentsJSON ?? "" }
    }
}

/// An explicit read route, independent of the normal reader's mark-read,
/// extraction, cache repair, AI automation, active account and SDK lifecycle.
struct ICloudArchiveReadingRepository: Sendable {
    let database: LibraryDatabase
    let accountID: String
    private static let pageSize = 100

    func catalog() async throws -> ICloudArchiveCatalog {
        try Task.checkCancellation()
        return try await database.readAsync { db in
            try validate(in: db)
            return .init(feeds: try FeedRecord.filter(Column("account_id") == accountID && Column("is_deleted") == false)
                .order(Column("sort_order"), Column("id")).fetchAll(db).map { .init(id: $0.id, name: $0.title) },
                folders: try FolderRecord.filter(Column("account_id") == accountID && Column("is_deleted") == false)
                .order(Column("sort_order"), Column("id")).fetchAll(db).map { .init(id: $0.id, name: $0.name) })
        }
    }

    func page(_ query: ICloudArchiveQuery) async throws -> ICloudArchivePage {
        try Task.checkCancellation()
        guard (0...100_000).contains(query.page), query.search.utf8.count <= 1_024 else { throw ICloudArchiveRecoveryError.safetyLimit }
        return try await database.readAsync { db in
            try validate(in: db)
            var args: [String: DatabaseValue] = ["account": accountID.databaseValue,
                "limit": (Self.pageSize + 1).databaseValue, "offset": (query.page * Self.pageSize).databaseValue]
            let search = query.search.trimmingCharacters(in: .whitespacesAndNewlines)
            let rows: [Row]
            switch query.section {
            case .articles:
                var clauses = ["i.account_id = :account", "f.account_id = i.account_id", "f.is_deleted = 0"]
                if query.starredOnly { clauses.append("s.is_starred = 1") }
                if let feed = query.feedID { clauses.append("i.feed_id = :feed"); args["feed"] = feed.databaseValue }
                if let folder = query.folderID {
                    clauses.append("""
                        EXISTS (SELECT 1 FROM feed_folders ff JOIN folders d ON d.id = ff.folder_id
                        WHERE ff.feed_id = f.id AND d.id = :folder AND d.account_id = :account AND d.is_deleted = 0)
                        """)
                    args["folder"] = folder.databaseValue
                }
                if !search.isEmpty {
                    clauses.append("(a.title LIKE :search ESCAPE '\\' OR a.author LIKE :search ESCAPE '\\')")
                    args["search"] = Self.likeLiteral(search).databaseValue
                }
                rows = try Row.fetchAll(db, sql: """
                    SELECT i.id, a.title, f.title AS source, s.is_read, s.is_starred,
                           COALESCE(a.published_at, i.created_at) AS date
                    FROM items i JOIN feeds f ON f.id = i.feed_id JOIN articles a ON a.item_id = i.id
                    LEFT JOIN article_states s ON s.item_id = i.id
                    WHERE \(clauses.joined(separator: " AND ")) ORDER BY date DESC, i.id DESC LIMIT :limit OFFSET :offset
                    """, arguments: StatementArguments(args))
            case .ai:
                var clause = Self.aiOwnership
                if !search.isEmpty {
                    clause += " AND (a.title LIKE :search ESCAPE '\\' OR ai.kind LIKE :search ESCAPE '\\' OR ai.selection_text LIKE :search ESCAPE '\\')"
                    args["search"] = Self.likeLiteral(search).databaseValue
                }
                rows = try Row.fetchAll(db, sql: """
                    SELECT ai.id, SUBSTR(COALESCE(a.title, NULLIF(ai.selection_text, ''), ''), 1, 200) AS title,
                           ai.kind AS source, 1 AS is_read,
                           0 AS is_starred, ai.updated_at AS date
                    FROM ai_artifacts ai LEFT JOIN items linked ON linked.account_id = :account
                      AND linked.id = COALESCE(ai.item_id, ai.subject_key)
                    LEFT JOIN articles a ON a.item_id = linked.id WHERE \(clause)
                    ORDER BY ai.updated_at DESC, ai.id DESC LIMIT :limit OFFSET :offset
                    """, arguments: StatementArguments(args))
            }
            return .init(items: rows.prefix(Self.pageSize).map {
                .init(id: $0["id"], title: HTMLTextDecoder.decoded($0["title"] ?? ""),
                    source: HTMLTextDecoder.decoded($0["source"] ?? ""), isRead: $0["is_read"] ?? false,
                    isStarred: $0["is_starred"] ?? false, date: ($0["date"] as Double?).map(Date.init(timeIntervalSince1970:)))
            }, hasMore: rows.count > Self.pageSize)
        }
    }

    func detail(id: String, section: ICloudArchiveQuery.Section) async throws -> ICloudArchiveDetail {
        try Task.checkCancellation()
        let raw: RawDetail = try await database.readAsync { db in
            try validate(in: db)
            if section == .ai {
                guard let artifact = try AIArtifactRecord.fetchOne(db, sql: "SELECT ai.* FROM ai_artifacts ai WHERE \(Self.aiOwnership) AND ai.id = :id",
                    arguments: ["account": accountID, "id": id]) else { throw ICloudArchiveRecoveryError.unavailableSource }
                let title = try String.fetchOne(db, sql: """
                    SELECT a.title FROM articles a JOIN items i ON i.id = a.item_id
                    WHERE i.account_id = ? AND i.id = ?
                    """, arguments: [accountID, artifact.itemID ?? artifact.subjectKey]) ?? artifact.selectionText ?? ""
                return .init(id: artifact.id, title: title, author: nil, url: nil,
                             html: nil, text: nil, source: .fallback, ai: [artifact])
            }
            guard let article = try ArticleRecord.fetchOne(db, sql: """
                SELECT a.* FROM articles a JOIN items i ON i.id = a.item_id JOIN feeds f ON f.id = i.feed_id
                WHERE i.id = ? AND i.account_id = ? AND f.account_id = i.account_id AND f.is_deleted = 0
                """, arguments: [id, accountID]) else { throw ICloudArchiveRecoveryError.unavailableSource }
            let cache = try ArticleCacheRecord.fetchOne(db, key: id)
            let rss = article.contentHTML?.trimmingCharacters(in: .whitespacesAndNewlines)
            let cached = cache?.html?.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasRSS = rss?.isEmpty == false, hasCache = cached?.isEmpty == false
            let ai = try AIArtifactRecord.fetchAll(db, sql: """
                SELECT ai.* FROM ai_artifacts ai WHERE \(Self.aiOwnership)
                  AND (ai.item_id = :id OR (ai.item_id IS NULL AND ai.subject_key = :id))
                ORDER BY ai.updated_at DESC, ai.id DESC LIMIT 100
                """, arguments: ["account": accountID, "id": id])
            return .init(id: id, title: HTMLTextDecoder.decoded(article.title), author: article.author.map(HTMLTextDecoder.decoded),
                url: article.url, html: hasRSS ? rss : hasCache ? cached : article.summary,
                text: cache?.text, source: hasRSS ? .feed : hasCache ? .cache : .fallback, ai: ai)
        }
        let rendering = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let document: ReaderDocument?
            if let html = raw.html {
                let content = ArticleExtractor.content(from: html, baseURL: nil)
                let fallback = raw.text ?? ""
                let safeHTML = content.html.isEmpty ? "<p>\(Self.escapedText(fallback).replacingOccurrences(of: "\n", with: "<br>"))</p>" : content.html
                let prepared = PreparedArticle(text: content.text.isEmpty ? fallback : content.text, html: safeHTML,
                    imageURLs: [], baseURL: nil, source: raw.source)
                document = content.html.isEmpty && fallback.isEmpty ? nil : ReaderDocumentRenderer.renderDocument(
                    article: prepared, documentIdentity: "archive|\(accountID)|\(raw.id)", extraStyleCSS: Self.style, resourcePolicy: .localArchive)
            } else { document = nil }
            try Task.checkCancellation()
            return ICloudArchiveDetail(id: raw.id, title: raw.title, author: raw.author,
                originalURL: Self.safeOriginalURL(raw.url), document: document, localAI: raw.ai.map(ICloudArchiveAIResult.init))
        }
        return try await withTaskCancellationHandler(operation: { try await rendering.value }, onCancel: { rendering.cancel() })
    }

    private func validate(in db: Database) throws {
        guard try ICloudLocalCopyRepository.copySource(accountID: accountID, in: db)?.isArchived == true
        else { throw ICloudArchiveRecoveryError.unavailableSource }
    }
    private struct RawDetail: Sendable {
        let id, title: String
        let author, url, html, text: String?
        let source: ArticleSource
        let ai: [AIArtifactRecord]
    }
    private static let aiOwnership = """
        ai.is_deleted = 0 AND (ai.account_id = :account OR (ai.account_id IS NULL AND EXISTS
        (SELECT 1 FROM items owned WHERE owned.account_id = :account
         AND (owned.id = ai.item_id OR (ai.item_id IS NULL AND owned.id = ai.subject_key)))))
        """
    private static func likeLiteral(_ value: String) -> String {
        "%" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_") + "%"
    }
    private static func safeOriginalURL(_ value: String?) -> URL? {
        guard let value, let c = URLComponents(string: value), ["http", "https"].contains(c.scheme?.lowercased() ?? ""),
              c.host?.isEmpty == false, c.user == nil, c.password == nil else { return nil }
        return c.url
    }
    private static func escapedText(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
    private static let style = """
        :root { color-scheme: light dark; } body { font-family: -apple-system, sans-serif; line-height: 1.7;
        max-width: 760px; margin: auto; padding: 16px 24px 40px; overflow-wrap: anywhere; }
        img { max-width: 100%; height: auto; } pre { overflow-x: auto; padding: 12px; background: rgba(128,128,128,.1); }
        blockquote { border-left: 3px solid #999; margin-left: 0; padding-left: 16px; } table { border-collapse: collapse; }
        th,td { padding: 6px 10px; border: 1px solid #999; }
        """
}
