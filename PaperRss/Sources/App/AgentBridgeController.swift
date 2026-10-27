import Foundation
#if SWIFT_PACKAGE
import PaperRssCore
import PaperRssAgentProtocol
#endif
#if os(macOS)
import AppKit
#endif

/// One process-owned endpoint. Only the App injects its already-open library.
@MainActor
final class AgentBridgeController: AgentBridge {
    static let shared = AgentBridgeController()
    static let enableKey = "PaperRss.agentMCPEnabled"
    private let defaults: UserDefaults
    private var database: LibraryDatabase?
    private var accountID = "local-default"
    private var sessions: [String: AgentLibraryService] = [:]
    private var generation = UUID()
    private var qaArticleIDs: [String] = []
    private var qaExpiresAt: Date?
    private var qaConsumed = false
    private var observers: [NSObjectProtocol] = []
    private(set) var transportFailure: String?
    #if os(macOS)
    private let directory: URL
    private var server: AgentIPCServer?
    #endif

    init(defaults: UserDefaults = .standard,
         directory: URL? = nil, launchArguments: [String] = CommandLine.arguments) {
        self.defaults = defaults
        #if os(macOS)
        self.directory = directory ?? AgentIPCPaths.defaultDirectory
        #endif
        // Explicit, process-scoped QA consent. Never read IDs or approval from MCP arguments.
        // Release builds ignore these switches. One launch grants one helper session only.
        #if DEBUG
        if launchArguments.contains("--agent-qa-allow-content-egress"),
           let index = launchArguments.firstIndex(of: "--agent-qa-content-ids"),
           index + 1 < launchArguments.count {
            let ids = launchArguments[index + 1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            if (1...20).contains(ids.count), Set(ids).count == ids.count,
               ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 }) {
                qaArticleIDs = ids
            }
        }
        #endif
    }

    /// App initialization owns this call; WindowGroup.onAppear must not create bridges.
    func attach(to store: AppStore) {
        guard database == nil, store.startupError == nil else { return }
        Task { [weak self] in
            do { try await self?.attach(database: store.libraryDatabase, accountID: store.localProvider.accountID) }
            catch { self?.transportFailure = (error as? AgentFailure)?.code ?? "IPC_UNAVAILABLE" }
        }
    }

    /// Also used by isolated tests; never constructs a database or starts a provider/sync job.
    func attach(database: LibraryDatabase, accountID: String = "local-default") async throws {
        guard self.database == nil else { return }
        self.database = database
        self.accountID = accountID
        qaExpiresAt = Date().addingTimeInterval(900)
        #if os(macOS)
        let endpoint = AgentIPCServer(directory: directory, handler: { [weak self] sessionID, tool, arguments in
            guard let self else { throw AgentFailure("APP_NOT_RUNNING", "PaperRss has stopped.") }
            return try await self.call(sessionID: sessionID, tool: tool, arguments: arguments)
        }, disconnected: { [weak self] sessionID in
            await self?.disconnect(sessionID: sessionID)
        })
        do {
            try endpoint.start(enabled: defaults.bool(forKey: Self.enableKey))
            server = endpoint
            transportFailure = nil
        } catch {
            self.database = nil
            endpoint.stop()
            throw error
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    do { try await self?.refreshEnablement() }
                    catch { self?.transportFailure = (error as? AgentFailure)?.code ?? "IPC_UNAVAILABLE" }
                }
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopTransport() }
            })
        #endif
    }

    func refreshEnablement() async throws {
        let enabled = defaults.bool(forKey: Self.enableKey)
        // Revoke even if filesystem state cannot be updated (for example a full disk).
        if !enabled { await revokeSessions() }
        #if os(macOS)
        try server?.setEnabled(enabled)
        #endif
    }

    private func readySession(id: String) async throws -> AgentLibraryService {
        guard defaults.bool(forKey: Self.enableKey) else {
            try await refreshEnablement()
            throw AgentFailure("NOT_ENABLED", "Enable local agent access in PaperRss first.")
        }
        guard let database else { throw AgentFailure("APP_NOT_RUNNING", "PaperRss is not ready.") }
        if let session = sessions[id] { return session }
        guard sessions.count < 16 else { throw AgentFailure("RATE_LIMITED", "Too many local agent sessions.") }
        let created = AgentLibraryService(database: database, accountID: accountID,
            policy: AgentAccessPolicy(enabled: true, accountIDs: [accountID], allowStarred: true))
        sessions[id] = created
        if !qaConsumed, !qaArticleIDs.isEmpty, let qaExpiresAt, Date() < qaExpiresAt {
            qaConsumed = true
            do { _ = try await created.authorizeContent(accountID: accountID, articleIDs: qaArticleIDs) }
            catch {
                sessions.removeValue(forKey: id)
                await created.revoke()
                throw error
            }
        }
        return created
    }

    func call(tool: String, arguments: [String: AgentJSON]) async throws -> AgentJSON {
        try await call(sessionID: "app", tool: tool, arguments: arguments)
    }

    private func call(sessionID: String, tool: String, arguments: [String: AgentJSON]) async throws -> AgentJSON {
        let requestGeneration = generation
        let service = try await readySession(id: sessionID)
        var response = try await service.call(tool: tool, arguments: arguments)
        guard defaults.bool(forKey: Self.enableKey), requestGeneration == generation,
              sessions[sessionID] === service else {
            throw AgentFailure("NOT_ENABLED", "Local agent access was revoked during the request.")
        }
        if tool == "paperrss_status", var status = response.objectValue {
            status["transport"] = .string(sessionID == "app" ? "in_process" : "unix_socket")
            status["paired"] = .bool(sessionID != "app")
            status["pair_state"] = .string(sessionID == "app" ? "app_internal" : "local_user_token")
            response = .object(status)
        }
        return response
    }

    /// Trusted App-only hook. Caller must obtain consent for the precise external session.
    func confirmContentSelection(articleIDs: [String], sessionID: String = "app") async throws -> String {
        let service = try await readySession(id: sessionID)
        return try await service.authorizeContent(accountID: accountID, articleIDs: articleIDs)
    }

    /// Still disabled by the real App session policy.
    func confirmStatePlan(planID: String) async throws -> String {
        try await readySession(id: "app").approve(planID: planID)
    }

    private func disconnect(sessionID: String) async {
        let previous = sessions.removeValue(forKey: sessionID)
        await previous?.revoke()
    }

    private func revokeSessions() async {
        generation = UUID()
        let previous = Array(sessions.values)
        sessions.removeAll()
        for service in previous { await service.revoke() }
    }

    /// Synchronous socket teardown is needed during process termination.
    private func stopTransport() {
        #if os(macOS)
        server?.stop()
        server = nil
        #endif
        generation = UUID()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    func stop() async {
        stopTransport()
        await revokeSessions()
        database = nil
    }
}
