import CryptoKit
import Foundation

public enum ICloudSyncIdentityError: Error, Equatable {
    case invalidFeedURL
}

/// Portable identities are separate from the existing local UUID/FNV identities.
/// Never normalize an opaque source item ID or reorder a feed's query parameters.
public enum ICloudSyncIdentity {
    public static func canonicalFeedURL(_ url: URL) throws -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty else {
            throw ICloudSyncIdentityError.invalidFeedURL
        }
        components.scheme = scheme
        components.host = host.lowercased()
        components.fragment = nil
        if (scheme == "https" && components.port == 443) ||
            (scheme == "http" && components.port == 80) {
            components.port = nil
        }
        guard let result = components.string else {
            throw ICloudSyncIdentityError.invalidFeedURL
        }
        return result
    }

    public static func feedRecordName(feedURL: URL) throws -> String {
        "feed-v1:" + digest([try canonicalFeedURL(feedURL)])
    }

    /// A nil identity means this article still needs source identity recovery.
    public static func articleRecordName(feedURL: URL, sourceItemID: String?) throws -> String? {
        guard let sourceItemID, hasSourceItemIdentity(sourceItemID) else {
            return nil
        }
        return "article-v1:" + digest([try canonicalFeedURL(feedURL), sourceItemID])
    }

    static func hasSourceItemIdentity(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    public static func membershipRecordName(feedRecordName: String, folderRecordName: String) -> String {
        "membership-v1:" + digest([feedRecordName, folderRecordName])
    }

    static func digest(_ parts: [String]) -> String {
        let encoded = parts.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(encoded.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Shared read-only link inspection. Neither the URL nor its parameters are
    /// rewritten. The hash is used only for previewing portable identity clashes.
    struct FeedLinkReview {
        let url: URL?
        let recordName: String?
        let hasCredentials: Bool
        let hasQuery: Bool
        let hasFragment: Bool
        var isUnverifiable: Bool { recordName == nil }
        var needsReview: Bool { hasCredentials || hasQuery || hasFragment || isUnverifiable }

        init(_ raw: String) {
            url = URL(string: raw, encodingInvalidCharacters: false)
            let parts = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
            hasCredentials = parts?.user != nil || parts?.password != nil
            hasQuery = parts?.query?.isEmpty == false
            hasFragment = parts?.fragment?.isEmpty == false
            recordName = url.flatMap { try? ICloudSyncIdentity.feedRecordName(feedURL: $0) }
        }
    }
}

/// Content retention must not change an article's read or starred state.
public enum ICloudArticleSyncPolicy {
    public static let staleStateInterval: TimeInterval = 183 * 24 * 60 * 60

    public static func shouldSyncContent(
        isRead: Bool, isStarred: Bool, syncUnreadContent: Bool
    ) -> Bool {
        isStarred || (!isRead && syncUnreadContent)
    }

    public static func canExpireState(
        isRead: Bool, isStarred: Bool, hasPendingChange: Bool,
        dateArrived: Date, cutoff: Date
    ) -> Bool {
        isRead && !isStarred && !hasPendingChange && dateArrived < cutoff
    }
}
