@preconcurrency import CloudKit
import Foundation
import Security

public enum CloudSyncError: LocalizedError, Equatable, Sendable {
    case notEntitled
    case legacyFormatUnsupported

    public var errorDescription: String? {
        switch self {
        case .notEntitled:
            return I18N.localized("此构建未启用 iCloud 权限：请使用开发者证书签名并在 Xcode 中开启 CloudKit capability。")
        case .legacyFormatUnsupported:
            return I18N.localized("旧版 iCloud 同步格式已停用。", englishFallback: "The legacy iCloud sync format is no longer supported.")
        }
    }
}

public struct CloudLibrary: Codable, Sendable {
    public var feeds: [Feed]
    public var readingStates: [String: ReadingState]
    public var artifacts: [AIArtifact]

    public init(feeds: [Feed], readingStates: [String: ReadingState], artifacts: [AIArtifact]) {
        self.feeds = feeds
        self.readingStates = readingStates
        self.artifacts = artifacts
    }

    static func from(_ database: AppDatabase) -> CloudLibrary {
        let states = database.readingStates.isEmpty ? Dictionary(uniqueKeysWithValues: database.entries.map { ($0.id, ReadingState(entryID: $0.id, isRead: $0.isRead, isStarred: $0.isStarred, updatedAt: $0.updatedAt)) }) : database.readingStates
        return CloudLibrary(feeds: database.feeds, readingStates: states, artifacts: database.artifacts)
    }

    static func merged(local: CloudLibrary, remote: CloudLibrary) -> CloudLibrary {
        func merge<T: Identifiable>(_ left: [T], _ right: [T], updatedAt: (T) -> Date) -> [T] where T.ID: Hashable {
            var values = Dictionary(uniqueKeysWithValues: left.map { ($0.id, $0) })
            for item in right where values[item.id].map({ updatedAt(item) > updatedAt($0) }) ?? true { values[item.id] = item }
            return Array(values.values)
        }
        var states = local.readingStates
        for (id, remoteState) in remote.readingStates where states[id].map({ remoteState.updatedAt > $0.updatedAt }) ?? true { states[id] = remoteState }
        return CloudLibrary(feeds: merge(local.feeds, remote.feeds, updatedAt: \.updatedAt), readingStates: states, artifacts: merge(local.artifacts, remote.artifacts, updatedAt: \.updatedAt))
    }
}

public actor CloudSyncService {
    public static let shared = CloudSyncService()

    /// Whether the running binary actually carries the CloudKit iCloud
    /// entitlement. Calling `CKContainer.default()` without it raises an
    /// Objective-C exception that Swift cannot catch and aborts the app
    /// (SIGABRT). Ad-hoc signed builds and plain SPM executables never carry
    /// the entitlement, so every CloudKit entry point must check this first
    /// instead of letting the framework throw.
    public static var isICloudEntitled: Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil),
              let services = value as? [String] else { return false }
        return services.contains("CloudKit")
        #else
        // SecTask is macOS-only, and iOS cannot query its runtime
        // entitlements. iOS is not a release target for now, so keep sync
        // disabled there until a real entitlement path (developer signing +
        // iCloud capability) exists for it.
        return false
        #endif
    }

    public func synchronize(_ local: CloudLibrary) async throws -> CloudLibrary {
        guard Self.isICloudEntitled else { throw CloudSyncError.notEntitled }
        // This prototype bundled AI artifacts and local identities into one
        // asset. Keep the compatibility API inert while callers move to the
        // account-scoped, whitelisted CKSyncEngine pipeline.
        throw CloudSyncError.legacyFormatUnsupported
    }
}
