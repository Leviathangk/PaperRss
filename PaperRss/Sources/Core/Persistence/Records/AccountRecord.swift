import Foundation
import GRDB

/// `accounts` 表的持久化映射模型。
///
/// 遵循 Architecture Contract (Section 8.1 / INV-01, INV-02)。
public struct AccountRecord: Codable, FetchableRecord, PersistableRecord, TableRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "accounts"

    public var id: String
    public var type: String
    public var displayName: String
    public var endpointURL: String?
    public var username: String?
    public var isEnabled: Bool
    public var isArchived: Bool
    public var createdAt: Double
    public var updatedAt: Double

    public init(
        id: String,
        type: String,
        displayName: String,
        endpointURL: String? = nil,
        username: String? = nil,
        isEnabled: Bool = true,
        isArchived: Bool = false,
        createdAt: Double,
        updatedAt: Double
    ) {
        self.id = id
        self.type = type
        self.displayName = displayName
        self.endpointURL = endpointURL
        self.username = username
        self.isEnabled = isEnabled
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case displayName = "display_name"
        case endpointURL = "endpoint_url"
        case username
        case isEnabled = "is_enabled"
        case isArchived = "is_archived"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    // Pre-v20 rows and legacy encoded account snapshots have no archive key.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        type = try values.decode(String.self, forKey: .type)
        displayName = try values.decode(String.self, forKey: .displayName)
        endpointURL = try values.decodeIfPresent(String.self, forKey: .endpointURL)
        username = try values.decodeIfPresent(String.self, forKey: .username)
        isEnabled = try values.decode(Bool.self, forKey: .isEnabled)
        isArchived = try values.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        createdAt = try values.decode(Double.self, forKey: .createdAt)
        updatedAt = try values.decode(Double.self, forKey: .updatedAt)
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["type"] = type
        container["display_name"] = displayName
        container["endpoint_url"] = endpointURL
        container["username"] = username
        container["is_enabled"] = isEnabled
        container["created_at"] = createdAt
        container["updated_at"] = updatedAt
        // Normal accounts can still populate a pre-v20 database in an upgrade
        // or restore. The latest schema supplies false on INSERT; omitting it
        // on UPDATE also cannot turn an existing archive back into an account.
        if isArchived { container["is_archived"] = true }
    }
}
