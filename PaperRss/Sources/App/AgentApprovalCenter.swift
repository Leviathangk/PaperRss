import SwiftUI
#if SWIFT_PACKAGE
import PaperRssCore
#endif
#if os(macOS)
import AppKit
#endif

/// App-owned consent queue. No IPC route can invoke its decision callbacks.
@MainActor
final class AgentApprovalCenter: ObservableObject {
    struct Key: Hashable { let sessionID: String; let planID: String }
    struct Request: Identifiable {
        let sessionID: String
        let planID: String
        let clientLabel: String?
        let actionKind: String
        let accountName: String
        let accountType: String
        let summary: String
        let affectedCount: Int
        let sampleTitles: [String]
        let notice: String
        let expiresAt: Date
        let summaryEnglish: String?
        init(sessionID: String, planID: String, clientLabel: String?, actionKind: String,
             accountName: String, accountType: String, summary: String, affectedCount: Int,
             sampleTitles: [String], notice: String, expiresAt: Date, summaryEnglish: String? = nil) {
            self.sessionID = sessionID
            self.planID = planID
            self.clientLabel = clientLabel
            self.actionKind = actionKind
            self.accountName = accountName
            self.accountType = accountType
            self.summary = summary
            self.affectedCount = affectedCount
            self.sampleTitles = sampleTitles
            self.notice = notice
            self.expiresAt = expiresAt
            self.summaryEnglish = summaryEnglish
        }
        var id: Key { Key(sessionID: sessionID, planID: planID) }
        var isDestructive: Bool { actionKind == "remove_feed" }
        var isFeedManagement: Bool { ["add_feed", "rename_feed", "remove_feed"].contains(actionKind) }
        @MainActor var warning: String {
            if isDestructive {
                return I18N.shared.localized("删除订阅源会移除其中的文章（包括收藏），并同步到该账号。此操作不可撤销。",
                    "Removing this feed deletes its articles, including starred articles, and updates this account. This cannot be undone.")
            }
            if isFeedManagement {
                return I18N.shared.localized("此更改将应用到所选账号。此操作不提供撤销。", "This change applies to the selected account. No undo is provided.")
            }
            return I18N.shared.localized("标为已读或取消收藏可能使文章符合自动清理条件。同步账号的更改将排队同步。此操作不提供撤销。",
                "Marking read or removing a star may make articles eligible for retention cleanup. Changes to synced accounts are queued for sync. No undo is provided.")
        }
    }
    typealias Decision = @MainActor () async throws -> Void
    private struct Actions { let approve: Decision; let deny: Decision }
    @Published private(set) var pending: [Request] = []
    @Published private(set) var busy: Set<Key> = []
    @Published private(set) var failed: Set<Key> = []
    private var actions: [Key: Actions] = [:]
    private let showPanel: Bool
    private let clock: () -> Date
    private var expiryTask: Task<Void, Never>?
    #if os(macOS)
    private var panel: NSPanel?
    #endif

    init(showPanel: Bool = true, clock: @escaping () -> Date = Date.init) {
        self.showPanel = showPanel
        self.clock = clock
    }

    func register(_ request: Request, approve: @escaping Decision, deny: @escaping Decision) {
        guard request.expiresAt > clock(), actions[request.id] == nil else { return }
        actions[request.id] = Actions(approve: approve, deny: deny)
        pending.append(request)
        scheduleExpiry()
        #if os(macOS)
        if showPanel { presentPanel() }
        #endif
    }

    func remove(sessionID: String) {
        for request in pending where request.sessionID == sessionID { actions.removeValue(forKey: request.id) }
        pending.removeAll { $0.sessionID == sessionID }
        didRemove()
    }

    func removeAll() {
        actions.removeAll()
        pending.removeAll()
        didRemove()
    }

    func expire() {
        let now = clock()
        for request in pending where request.expiresAt <= now { actions.removeValue(forKey: request.id) }
        pending.removeAll { $0.expiresAt <= now }
        didRemove()
    }

    /// Called by the two App buttons only; neither decision is a wire operation.
    func approve(_ request: Request) async { await decide(request, approval: true) }
    func deny(_ request: Request) async { await decide(request, approval: false) }

    private func decide(_ request: Request, approval: Bool) async {
        expire()
        guard let action = actions[request.id], !busy.contains(request.id) else { return }
        busy.insert(request.id)
        failed.remove(request.id)
        do {
            try await (approval ? action.approve : action.deny)()
            actions.removeValue(forKey: request.id)
            pending.removeAll { $0.id == request.id }
        } catch {
            // Do not display arbitrary provider errors or private account details.
            if actions[request.id] != nil { failed.insert(request.id) }
        }
        busy.remove(request.id)
        didRemove()
    }

    private func didRemove() {
        let keys = Set(pending.map(\.id))
        busy.formIntersection(keys)
        failed.formIntersection(keys)
        scheduleExpiry()
        #if os(macOS)
        if pending.isEmpty { panel?.orderOut(nil) }
        #endif
    }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        guard let expiry = pending.map(\.expiresAt).min() else { expiryTask = nil; return }
        let delay = max(0.001, min(expiry.timeIntervalSince(clock()), 900))
        expiryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            self?.expire()
        }
    }

    #if os(macOS)
    private func presentPanel() {
        if panel == nil {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 340),
                styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.isFloatingPanel = true
            window.hidesOnDeactivate = false
            window.level = .floating
            window.contentView = NSHostingView(rootView: AgentApprovalList(center: self)
                .frame(minWidth: 400, minHeight: 200).accessibilityIdentifier("agent.approval.panel"))
            window.center()
            panel = window
        }
        updatePanelTitle()
        panel?.orderFrontRegardless()
        NSApp.requestUserAttention(.informationalRequest)
    }
    #endif

    fileprivate func fitPanel(to contentHeight: CGFloat) {
        #if os(macOS)
        guard let panel, !pending.isEmpty, contentHeight > 0 else { return }
        let availableHeight = (panel.screen?.visibleFrame.height ?? 800) - 100
        let height = min(max(200, contentHeight), min(560, availableHeight))
        let size = panel.frameRect(forContentRect: NSRect(x: 0, y: 0,
            width: panel.contentLayoutRect.width, height: height)).size
        guard abs(panel.frame.height - size.height) > 1 else { return }
        // Keep the top edge stable as requests arrive, expire, or change language.
        panel.setFrame(NSRect(x: panel.frame.minX, y: panel.frame.maxY - size.height,
            width: size.width, height: size.height), display: true)
        #endif
    }

    fileprivate func updatePanelTitle() {
        #if os(macOS)
        panel?.title = I18N.shared.localized("Agent 请求批准", "Agent Approval Request")
        #endif
    }
}

struct AgentApprovalList: View {
    @ObservedObject var center: AgentApprovalCenter
    @ObservedObject private var i18n = I18N.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(center.pending) { request in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(verbatim: source(request.clientLabel)).font(.subheadline).foregroundStyle(.secondary)
                        Text(verbatim: clipped(request.accountName, limit: 120) + " · " + clipped(request.accountType, limit: 40))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(verbatim: actionTitle(request.actionKind)).font(.headline)
                        Text(verbatim: clipped(i18n.localized(request.summary, request.summaryEnglish ?? request.summary), limit: 600))
                            .fixedSize(horizontal: false, vertical: true)
                        if request.affectedCount > 0 || !request.sampleTitles.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: i18n.localized("影响 \(request.affectedCount) 篇文章", "Affects \(request.affectedCount) articles"))
                                    .font(.caption).fontWeight(.medium)
                                ForEach(Array(request.sampleTitles.prefix(3).enumerated()), id: \.offset) { _, title in
                                    Text(verbatim: "• " + clipped(title, limit: 160))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                        Text(verbatim: request.warning)
                            .font(.caption).foregroundStyle(request.isDestructive ? Color.red : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("agent.approval.warning.\(request.planID)")
                        Text(i18n.localized("到期时间：", "Expires: ") + request.expiresAt.formatted(date: .omitted, time: .standard))
                            .font(.caption).foregroundStyle(.secondary)
                        if center.failed.contains(request.id) {
                            Text(i18n.localized("操作未完成，请重试或等待请求到期。", "Could not complete the decision. Retry or wait for expiry."))
                                .font(.caption).foregroundStyle(.red)
                        }
                        HStack(spacing: 8) {
                            Spacer()
                            Button(i18n.localized("拒绝", "Deny")) { Task { await center.deny(request) } }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("agent.approval.deny.\(request.planID)")
                            Button(i18n.localized("批准", "Approve")) { Task { await center.approve(request) } }
                                .buttonStyle(.borderedProminent)
                                .tint(request.isDestructive ? Color.red : Color.accentColor)
                                .accessibilityIdentifier("agent.approval.approve.\(request.planID)")
                            // Deliberately no defaultAction / Return keyboard shortcut.
                        }
                        .disabled(center.busy.contains(request.id))
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(16)
            .background(GeometryReader { geometry in
                Color.clear.preference(key: AgentApprovalContentHeight.self, value: geometry.size.height)
            })
        }
        .onPreferenceChange(AgentApprovalContentHeight.self) { center.fitPanel(to: $0) }
        .onChange(of: i18n.isEnglish) { center.updatePanelTitle() }
    }

    private func actionTitle(_ kind: String) -> String {
        switch kind {
        case "add_feed": return i18n.localized("添加订阅源", "Add Feed")
        case "rename_feed": return i18n.localized("重命名订阅源", "Rename Feed")
        case "remove_feed": return i18n.localized("删除订阅源（不可撤销）", "Remove Feed (Cannot Be Undone)")
        case "mark_read": return i18n.localized("批量标为已读", "Mark Articles Read")
        case "state_change": return i18n.localized("更改已读或收藏状态", "Change Read or Starred State")
        default: return i18n.localized("更改文章状态", "Change Article State")
        }
    }

    private func source(_ label: String?) -> String {
        guard let label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return i18n.localized("未知助手", "Unknown assistant")
        }
        return i18n.localized("来自 \(clipped(label, limit: 80))（自报）", "From \(clipped(label, limit: 80)) (self-reported)")
    }
    private func clipped(_ value: String, limit: Int) -> String {
        let plain = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let text = String(String.UnicodeScalarView(plain.prefix(limit)))
        return plain.count > limit ? text + "…" : text
    }
}

private struct AgentApprovalContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
