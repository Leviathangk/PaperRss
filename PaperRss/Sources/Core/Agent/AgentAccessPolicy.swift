import Foundation
#if SWIFT_PACKAGE
import PaperRssAgentProtocol
#endif

public struct AgentAccessPolicy: Sendable {
    public var enabled: Bool
    public var accountIDs: Set<String>
    public let allowStarred: Bool
    public let allowStateChanges: Bool
    public let outputCharacterBudget: Int
    public init(enabled: Bool = false, accountIDs: Set<String> = [], allowStarred: Bool = false,
                allowStateChanges: Bool = false, outputCharacterBudget: Int = 100_000) {
        self.enabled = enabled
        self.accountIDs = accountIDs
        self.allowStarred = allowStarred
        self.allowStateChanges = allowStateChanges
        self.outputCharacterBudget = min(max(outputCharacterBudget, 0), 100_000)
    }
}

public enum AgentStateField: String, Codable, Sendable { case read, starred }

public struct AgentStatePlan: Codable, Sendable {
    public let plan_id: String
    public let account_id: String
    public let article_ids: [String]
    public let field: AgentStateField
    public let value: Bool
    public let expires_at: Date
    public let retention_notice: String
}

public struct AgentStateReceipt: Codable, Sendable, Equatable {
    public let operation_id: String
    public let applied_count: Int
    public let local_commit: String
    public let sync: String
}

public struct AgentArticleMetadata: Codable, Sendable {
    public let id: String
    public let account_id: String
    public let feed_id: String
    public let title: String
    public let authors: [String]
    public let source_url: String?
    public let source_url_unavailable_reason: String?
    public let feed_title: String
    public let published_at: Date?
    public let read: Bool
    public let starred: Bool
    public let state_token: String
    public let excerpt: String
    public let content_available: Bool
    public let content_source: String
    public let retrieved_at: Date
    public let truncated: Bool
    public let untrusted: Bool
}

/// Validated navigation intent; UI execution belongs to the App process.
public struct AgentOpenRequest: Sendable, Equatable {
    public let accountID: String
    public let feedID: UUID
    public let articleID: String?
    public init(accountID: String, feedID: UUID, articleID: String? = nil) {
        self.accountID = accountID
        self.feedID = feedID
        self.articleID = articleID
    }
}

public enum AgentAccountSnapshots {
    /// Explicit allowlist: endpoint, username and sync errors never enter the wire DTO.
    public static func read(database: LibraryDatabase, accounts: [AccountRecord]? = nil,
                                 syncStates: [String: AccountSyncStateRecord]? = nil,
                                 canOpen: Bool = false) throws -> [AgentJSON] {
        let repository = AccountRepository(database: database)
        let records = try accounts ?? database.read { try repository.fetchAllAccounts(in: $0) }
        return try records.map { account in
            let provider = LocalAccountProvider(accountID: account.id, database: database)
            let feeds = try provider.fetchFeeds()
            let counts = try provider.timelineQueryService.fetchSidebarCounts(accountID: account.id, startOfDayTimestamp: 0)
            let sync = try syncStates?[account.id] ?? database.read { try repository.fetchSyncState(accountID: account.id, in: $0) }
            let timestamp = sync?.lastSyncCompletedAt ?? (account.type == AccountType.local.rawValue
                ? feeds.compactMap(\.lastRefreshedAt).max()?.timeIntervalSince1970 : nil)
            var host: String?
            if [AccountType.freshRSS.rawValue, AccountType.miniflux.rawValue].contains(account.type),
               let raw = account.endpointURL, let url = URLComponents(string: raw),
               ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
               let value = url.host, !value.isEmpty,
               !value.contains("@"), !value.contains("%"), !value.contains("/"),
               !value.contains("?"), !value.contains("#") {
                host = value + (url.port.map { ":\($0)" } ?? "")
            }
            return .object([
                "account_id": .string(account.id), "type": .string(account.type),
                "display_name": .string(account.displayName), "enabled": .bool(account.isEnabled),
                "server_host": host.map(AgentJSON.string) ?? .null,
                "feed_count": .number(Double(feeds.count)), "unread_count": .number(Double(counts.allUnread)),
                "last_sync_at": timestamp.map { .string(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0))) } ?? .null,
                "capabilities": .array((account.isEnabled ? ["metadata.read", "content.read.selection"] + (canOpen ? ["ui.open"] : []) : []).map(AgentJSON.string))
            ])
        }
    }
}
