import Foundation
#if SWIFT_PACKAGE
import PaperRssCore
import PaperRssAgentProtocol
#endif

/// Process-level bridge seam, not a window listener. No IPC listener is installed in the spike.
/// TODO(production): UDS owner/peer validation, pairing, per-client sessions and global quotas,
/// confirmation UI, revocation on disconnect, signed helper packaging and lifecycle QA.
@MainActor
final class AgentBridgeController: AgentBridge {
    static let shared = AgentBridgeController()
    static let enableKey = "PaperRss.agentMCPEnabled"
    private let defaults: UserDefaults
    private weak var store: AppStore?
    private var session: AgentLibraryService?

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// App initialization owns this call; WindowGroup.onAppear must not create bridges.
    func attach(to store: AppStore) {
        guard self.store == nil else { return }
        self.store = store
    }

    private func readySession() async throws -> AgentLibraryService {
        guard defaults.bool(forKey: Self.enableKey) else {
            await stop()
            throw AgentFailure("NOT_ENABLED", "Enable local agent access in PaperRss first.")
        }
        guard let store else { throw AgentFailure("APP_NOT_RUNNING", "PaperRss is not ready.") }
        if let session { return session }
        // App already owns this database. Never open a second LibraryDatabase from a helper.
        // Keep real-app writes disabled until retention/confirmation UI and IPC QA are complete.
        let created = AgentLibraryService(database: store.libraryDatabase,
            policy: AgentAccessPolicy(enabled: true, accountIDs: [store.localProvider.accountID]))
        session = created
        return created
    }

    func call(tool: String, arguments: [String: AgentJSON]) async throws -> AgentJSON {
        let service = try await readySession()
        let response = try await service.call(tool: tool, arguments: arguments)
        guard defaults.bool(forKey: Self.enableKey) else {
            await stop()
            throw AgentFailure("NOT_ENABLED", "Local agent access was disabled during the request.")
        }
        // Future enabled writes must invalidate existing AppStore projections after commit.
        if tool == "paperrss_apply_state_change" { store?.reloadState() }
        return response
    }

    /// Trusted UI hook. Not registered in tools/list and not reachable by external tool arguments.
    /// Caller must first explain external content egress and get the user's explicit selection consent.
    func confirmContentSelection(articleIDs: [String]) async throws -> String {
        let service = try await readySession()
        guard let store else { throw AgentFailure("APP_NOT_RUNNING", "PaperRss is not ready.") }
        return try await service.authorizeContent(accountID: store.localProvider.accountID, articleIDs: articleIDs)
    }

    /// Trusted confirmation hook; remains disabled for real app state writes in this spike.
    func confirmStatePlan(planID: String) async throws -> String {
        try await readySession().approve(planID: planID)
    }

    func stop() async {
        let previous = session
        session = nil
        await previous?.revoke()
    }
}
