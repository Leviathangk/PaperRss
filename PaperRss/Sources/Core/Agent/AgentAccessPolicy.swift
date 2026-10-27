import Foundation
#if SWIFT_PACKAGE
import PaperRssAgentProtocol
#endif

public struct AgentAccessPolicy: Sendable {
    public var enabled: Bool
    public let accountIDs: Set<String>
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
