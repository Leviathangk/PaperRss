import SwiftUI
#if SWIFT_PACKAGE
import PaperRssCore
#endif

struct ICloudRetentionMaintenanceControls: View {
    @ObservedObject var store: AppStore
    let accountID: String
    @State private var status: ICloudRetentionMaintenanceStatus?
    @State private var review: ICloudRetentionMaintenanceReview?
    @State private var cleanupConfirmed = false
    @State private var futureConfirmed = false
    @State private var clockConfirmed = false
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var operation: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(I18N.localized("持续检查当前 iCloud 资料范围，处理现在及以后符合 183 天规则的历史记录。每周共享额度最多 400 条，收藏、允许同步的未读正文和待同步修改受到保护；新设备可恢复的历史范围会缩短。本机文章和 AI 产物保留。", englishFallback: "Continuously check this iCloud library for current and future records eligible under the 183-day rule. The shared weekly limit is 400 records. Stars, permitted unread content and pending changes are protected. New devices can recover less history. Local articles and AI results are retained."))
            Text(I18N.localized("核验服务器时间需要额外控制保存，不计入上述 400 条历史清理额度。", englishFallback: "Verifying server time requires extra control saves outside the 400-record history cleanup limit."))
                .foregroundStyle(.secondary)
            Text(I18N.localized("关闭窗口会让已启用的维护继续运行。停用会阻止后续请求；已经提交的请求仍可能完成，原操作记录保留。", englishFallback: "Enabled maintenance continues after closing this window. Disabling it stops subsequent requests. Already submitted requests may still finish, and their operation records are retained."))
                .foregroundStyle(.secondary)
            if let status, status.isEnabled {
                Label(I18N.localized("持续维护已启用", englishFallback: "Ongoing Maintenance Enabled"), systemImage: "checkmark.circle")
                if status.needsOutcomeReview {
                    Text(I18N.localized("当前任务有结果需要复核，暂不生成下一批任务。请停用后读取原请求结果。", englishFallback: "The current task has outcomes needing review, so no new batch is created. Disable maintenance before reading the original request outcomes."))
                        .foregroundStyle(.orange)
                }
                if let date = status.nextWakeAt {
                    HStack {
                        Text(I18N.localized("下次发现时间：", englishFallback: "Next discovery:"))
                        Text(date, style: .relative)
                    }
                    .foregroundStyle(.secondary)
                }
                HStack {
                    Button(I18N.localized("停用持续维护", englishFallback: "Disable Ongoing Maintenance")) {
                        run { try await store.stopICloudRetentionMaintenance(accountID: accountID, approvalID: status.approvalID) }
                    }
                    .accessibilityIdentifier("icloud.maintenanceStop")
                    Button(I18N.localized("继续已启用的维护", englishFallback: "Continue Enabled Maintenance")) {
                        run { try await store.resumeICloudRetentionMaintenance(accountID: accountID) }
                    }
                    .disabled(status.needsOutcomeReview)
                    .accessibilityIdentifier("icloud.maintenanceResume")
                }
                if let message = status.failureMessage { Text(message).foregroundStyle(.orange) }
            } else if let review {
                Text(I18N.localized(review.resumesExistingApproval ? "重新启用将沿用原授权、任务编号和等待时间。" : "本次确认包含以后符合条件的文章，请单独审阅这一范围。",
                    englishFallback: review.resumesExistingApproval ? "Re-enabling preserves the original consent, task identifiers and retry wait." : "This consent includes future eligible articles. Review that scope separately."))
                    .foregroundStyle(.secondary)
                Toggle(I18N.localized("我确认历史清理会影响其他设备能够恢复的资料范围。", englishFallback: "I confirm that history cleanup affects what other devices can recover."), isOn: $cleanupConfirmed)
                    .accessibilityIdentifier("icloud.maintenanceCleanupConsent")
                Toggle(I18N.localized("我授权持续维护现在及以后的合格文章，直至主动停用。", englishFallback: "I authorize ongoing maintenance of current and future eligible articles until I disable it."), isOn: $futureConfirmed)
                    .accessibilityIdentifier("icloud.maintenanceFutureConsent")
                Toggle(I18N.localized("我单独允许核验服务器时间所需的额外控制保存。", englishFallback: "I separately allow the extra control saves needed to verify server time."), isOn: $clockConfirmed)
                    .accessibilityIdentifier("icloud.maintenanceClockConsent")
                Button(I18N.localized("确认并启用持续维护", englishFallback: "Confirm and Enable Ongoing Maintenance")) {
                    run {
                        try await store.enableICloudRetentionMaintenance(accountID: accountID, reviewID: review.id,
                            cleanupConfirmed: cleanupConfirmed, futureArticlesConfirmed: futureConfirmed,
                            clockMaintenanceConfirmed: clockConfirmed)
                        self.review = nil
                    }
                }
                .disabled(!cleanupConfirmed || !futureConfirmed || !clockConfirmed)
                .accessibilityIdentifier("icloud.maintenanceEnable")
            } else {
                Button(I18N.localized("审阅持续维护授权", englishFallback: "Review Ongoing Maintenance Consent")) {
                    run {
                        let value = try await store.prepareICloudRetentionMaintenanceReview(accountID: accountID)
                        guard !Task.isCancelled else {
                            await store.discardICloudRetentionMaintenanceReview(accountID: accountID, id: value.id); return
                        }
                        review = value; cleanupConfirmed = false; futureConfirmed = false; clockConfirmed = false
                    }
                }
                .accessibilityIdentifier("icloud.maintenancePrepare")
            }
            if isBusy { ProgressView().controlSize(.small) }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) }
        }
        .disabled(isBusy)
        .task {
            await loadStatus()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                await loadStatus()
            }
        }
        .onDisappear {
            operation?.cancel()
            if let review { Task { await store.discardICloudRetentionMaintenanceReview(accountID: accountID, id: review.id) } }
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true; errorMessage = nil
        operation = Task {
            defer { isBusy = false }
            do { try await action(); await loadStatus() }
            catch is CancellationError { }
            catch { if !Task.isCancelled { errorMessage = store.iCloudErrorMessage(error) } }
        }
    }
    private func loadStatus() async {
        do {
            let value = try await store.iCloudRetentionMaintenanceStatus(accountID: accountID)
            guard !Task.isCancelled else { return }
            status = value
        } catch is CancellationError { }
        catch { if !Task.isCancelled { errorMessage = store.iCloudErrorMessage(error) } }
    }
}
