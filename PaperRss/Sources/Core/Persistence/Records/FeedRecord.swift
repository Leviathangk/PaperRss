import Foundation
import GRDB

/// `feeds` 表的持久化映射模型。
///
/// 遵循 Architecture Contract (Section 8.3 / INV-02, INV-03)。
public struct FeedRecord: Codable, FetchableRecord, PersistableRecord, TableRecord, Sendable, Equatable {
    public static let databaseTableName = "feeds"

    public var id: String
    public var accountID: String
    public var externalID: String?
    public var title: String
    public var customTitle: String?
    public var originalTitle: String?
    public var siteURL: String?
    public var feedURL: String
    public var etag: String?
    public var lastModified: String?
    public var lastRefreshedAt: Double?
    public var isDeleted: Bool
    public var updatedAt: Double
    public var storedIconURL: String?
    public var sortOrder: Int

    public init(
        id: String,
        accountID: String,
        externalID: String? = nil,
        title: String,
        customTitle: String? = nil,
        originalTitle: String? = nil,
        siteURL: String? = nil,
        feedURL: String,
        etag: String? = nil,
        lastModified: String? = nil,
        lastRefreshedAt: Double? = nil,
        isDeleted: Bool = false,
        updatedAt: Double,
        storedIconURL: String? = nil,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.accountID = accountID
        self.externalID = externalID
        self.title = title
        self.customTitle = customTitle
        self.originalTitle = originalTitle
        self.siteURL = siteURL
        self.feedURL = feedURL
        self.etag = etag
        self.lastModified = lastModified
        self.lastRefreshedAt = lastRefreshedAt
        self.isDeleted = isDeleted
        self.updatedAt = updatedAt
        self.storedIconURL = storedIconURL
        self.sortOrder = sortOrder
    }

    enum CodingKeys: String, CodingKey {
        case id
        case accountID = "account_id"
        case externalID = "external_id"
        case title
        case customTitle = "custom_title"
        case originalTitle = "original_title"
        case siteURL = "site_url"
        case feedURL = "feed_url"
        case etag
        case lastModified = "last_modified"
        case lastRefreshedAt = "last_refreshed_at"
        case isDeleted = "is_deleted"
        case updatedAt = "updated_at"
        case storedIconURL = "stored_icon_url"
        case sortOrder = "sort_order"
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["account_id"] = accountID
        container["external_id"] = externalID
        container["title"] = title
        container["site_url"] = siteURL
        container["feed_url"] = feedURL
        container["etag"] = etag
        container["last_modified"] = lastModified
        container["last_refreshed_at"] = lastRefreshedAt
        container["is_deleted"] = isDeleted
        container["updated_at"] = updatedAt
        container["stored_icon_url"] = storedIconURL
        container["sort_order"] = sortOrder
        // Pre-v24 databases in migration tests may lack custom_title/original_title.
        // Omit them when nil so inserting pre-v24 records succeeds without unknown column errors.
        if let customTitle { container["custom_title"] = customTitle }
        if let originalTitle { container["original_title"] = originalTitle }
    }
}
