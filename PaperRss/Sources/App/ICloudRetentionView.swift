import SwiftUI
#if SWIFT_PACKAGE
import PaperRssCore
#endif

struct ICloudRetentionView: View {
    private enum Mode: Hashable { case finite, maintenance }
    @ObservedObject var store: AppStore
    let accountID: String
    @Environment(\.dismiss) private var dismiss
    @State private var review: ICloudRetentionReview?
    @State private var progress: ICloudRetentionProgress?
    @State private var cleanupConfirmed = false
    @State private var clockConfirmed = false
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var operation: Task<Void, Never>?
    @State private var mode: Mode = .finite
    @State private var maintenance: ICloudRetentionMaintenanceStatus?
    @State private var hasLoadedMode = false
    @State private var outcomeResult: ICloudRetentionOutcomeReviewResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(I18N.localized("云端历史清理", englishFallback: "Cloud History Cleanup"))
                .font(.title2.weight(.semibold))
            Picker(I18N.localized("维护范围", englishFallback: "Maintenance Scope"), selection: $mode) {
                Text(I18N.localized("本次有限任务", englishFallback: "This Finite Task")).tag(Mode.finite)
                Text(I18N.localized("持续自动维护", englishFallback: "Ongoing Automatic Maintenance")).tag(Mode.maintenance)
            }
            .pickerStyle(.segmented)
            .disabled(isBusy)
            .accessibilityIdentifier("icloud.retentionMode")
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if mode == .maintenance {
                        ICloudRetentionMaintenanceControls(store: store, accountID: accountID)
                    } else {
                        Text(I18N.localized("先核验并审阅本次有限范围。收藏、允许同步的未读正文、最近修改和本机待发送资料受保护；本机文章、阅读状态与 AI 资料保留。", englishFallback: "Verify and review a finite scope first. Stars, eligible unread content, recent changes and pending local data are protected. Articles, reading states and AI data on this Mac are retained."))
                        Text(I18N.localized("历史状态保留 183 天，每周最多处理 400 条云端记录，包括清理组的保护保存。清理可能减少其他设备能恢复的历史；之后新增的文章需要另行审阅。", englishFallback: "Historical states are retained for 183 days. At most 400 cloud records are processed per week, including protection saves in cleanup groups. Cleanup may reduce history recoverable on other devices. Articles added later need a separate review."))
                            .foregroundStyle(.secondary)
                        if let review {
                            Divider()
                            Text(I18N.shared.localizedFormat("本次最多逐条核验 %lld 篇文章，仅处理执行时仍符合规则的记录。", review.candidateArticles))
                            Text(review.scannedAt, style: .date).foregroundStyle(.secondary)
                            Toggle(I18N.localized("我已审阅本次历史恢复与隐私影响，确认清理符合规则的云端记录。", englishFallback: "I reviewed the history recovery and privacy effects and approve cleanup of eligible cloud records."), isOn: $cleanupConfirmed)
                                .accessibilityIdentifier("icloud.retentionConfirmCleanup")
                            Text(I18N.localized("为避免本机时钟影响周配额，任务还会保存时间校验控制记录。这些额外控制写入不计入上述 400 条历史清理组额度，不删除正文或状态。", englishFallback: "The task also saves time-verification control records so the device clock cannot renew the weekly quota. These extra control writes are outside the 400-record cleanup-group budget and do not delete content or states."))
                                .foregroundStyle(.secondary)
                            Toggle(I18N.localized("我单独同意本次任务的额外时间校验控制写入。", englishFallback: "I separately approve extra time-verification control writes for this task."), isOn: $clockConfirmed)
                                .accessibilityIdentifier("icloud.retentionConfirmClock")
                        }
                        if isBusy { ProgressView().controlSize(.small) }
                        if let errorMessage { Text(errorMessage).foregroundStyle(.orange) }
                        Text(I18N.localized("关闭窗口后，已批准任务仍可在后台进行。停止会保留具体阶段，已发出的云端请求需核验结果后才能继续。", englishFallback: "Approved tasks can continue in the background after this window closes. Stopping retains their stage. The outcome of an already submitted cloud request must be verified before continuing."))
                            .foregroundStyle(.secondary)
                    }
                    if let progress { progressContent(progress) }
                    if let outcomeResult {
                        Text(I18N.shared.localizedFormat("本次复核确认 %lld 项，仍无法确认 %lld 项，另有 %lld 项待复核。",
                            outcomeResult.confirmedOperations, outcomeResult.unresolvedOperations, outcomeResult.remainingOperations))
                        Text(I18N.localized("复核只读取原请求的云端证据；未能确认的原操作仍保留，不重复删除。", englishFallback: "Review only reads cloud evidence for original requests. Unconfirmed operations are retained, and deletions are not repeated."))
                            .foregroundStyle(.secondary)
                    }
                    if mode == .maintenance, isBusy { ProgressView().controlSize(.small) }
                    if mode == .maintenance, let errorMessage { Text(errorMessage).foregroundStyle(.orange) }
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if mode == .finite, let review {
                    Button(I18N.localized("开始本次清理", englishFallback: "Start This Cleanup"), role: .destructive) {
                        run { try await store.startICloudRetention(accountID: accountID, reviewID: review.id,
                            cleanupConfirmed: cleanupConfirmed, clockMaintenanceConfirmed: clockConfirmed)
                            self.review = nil
                        }
                    }
                    .disabled(isBusy || !cleanupConfirmed || !clockConfirmed)
                    .accessibilityIdentifier("icloud.retentionStart")
                } else if mode == .finite, maintenance?.isEnabled != true,
                          progress == nil || (progress?.isFinished == true && progress?.articlesNeedingReview == 0) {
                    Button(I18N.localized("读取或继续核验候选", englishFallback: "Read or Continue Verifying Candidates")) {
                        run {
                            let value = try await store.prepareICloudRetentionReview(accountID: accountID)
                            guard !Task.isCancelled else {
                                await store.discardICloudRetentionReview(accountID: accountID, id: value.id)
                                return
                            }
                            review = value; cleanupConfirmed = false; clockConfirmed = false
                        }
                    }
                    .disabled(isBusy)
                    .accessibilityIdentifier("icloud.retentionPrepare")
                }
                if let progress, !progress.isFinished {
                    if progress.isEnabled {
                        Button(I18N.localized(progress.isMaintenanceTask ? "停用持续维护" : "停止本次任务",
                            englishFallback: progress.isMaintenanceTask ? "Disable Ongoing Maintenance" : "Stop This Task")) {
                            run { try await store.stopICloudRetention(accountID: accountID, approvalID: progress.approvalID) }
                        }
                        .accessibilityIdentifier("icloud.retentionStop")
                    } else if !progress.isMaintenanceTask || maintenance?.isEnabled == true {
                        Button(I18N.localized("继续已批准任务", englishFallback: "Continue the Approved Task")) {
                            run { try await store.resumeICloudRetention(accountID: accountID, approvalID: progress.approvalID) }
                        }
                        .accessibilityIdentifier("icloud.retentionResume")
                    }
                }
                if let progress, progress.uncertainOperations > 0, !progress.isEnabled {
                    Button(I18N.localized("只读复核原请求结果", englishFallback: "Read-Only Review of Original Outcomes")) {
                        run {
                            outcomeResult = try await store.reviewICloudRetentionOutcomes(accountID: accountID,
                                                                                          approvalID: progress.approvalID)
                        }
                    }
                    .accessibilityIdentifier("icloud.retentionOutcomeReview")
                }
                Spacer()
                Button(I18N.localized("完成", englishFallback: "Done")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .disabled(isBusy)
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 420, maxHeight: 680)
        .task {
            await loadProgress()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                await loadProgress()
            }
        }
        .onDisappear {
            operation?.cancel()
            if let review {
                Task { await store.discardICloudRetentionReview(accountID: accountID, id: review.id) }
            }
        }
        .onChange(of: mode) { _, _ in
            if let review { Task { await store.discardICloudRetentionReview(accountID: accountID, id: review.id) } }
            review = nil; cleanupConfirmed = false; clockConfirmed = false
        }
        .accessibilityIdentifier("icloud.retentionSheet")
    }

    private func progressContent(_ progress: ICloudRetentionProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text(I18N.shared.localizedFormat("已完成 %lld 篇，已跳过 %lld 篇，待处理 %lld 篇，需要复核 %lld 篇。",
                progress.completedArticles, progress.skippedArticles, progress.remainingArticles, progress.articlesNeedingReview))
            Text(I18N.shared.localizedFormat("本次已确认处理 %lld 条云端记录。", progress.processedRecords))
            if let date = progress.nextWakeAt, progress.isEnabled {
                HStack {
                    Text(I18N.localized("下次核验时间：", englishFallback: "Next verification:"))
                    Text(date, style: .relative)
                }
                .foregroundStyle(.secondary)
            }
            if progress.articlesNeedingReview > 0 {
                Text(I18N.localized("部分请求的结果或证据需要复核；保留原操作记录，暂不能替换为新任务。", englishFallback: "Some request outcomes or evidence need review. Their operation records are retained and cannot be replaced by a new task yet."))
                    .foregroundStyle(.orange)
            }
            if let message = progress.failureMessage { Text(message).foregroundStyle(.orange) }
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true; errorMessage = nil
        operation = Task {
            defer { isBusy = false }
            do { try await action(); await loadProgress() }
            catch is CancellationError { }
            catch { if !Task.isCancelled { errorMessage = store.iCloudErrorMessage(error) } }
        }
    }
    private func loadProgress() async {
        do {
            let value = try await store.iCloudRetentionProgress(accountID: accountID)
            let policy = try await store.iCloudRetentionMaintenanceStatus(accountID: accountID)
            guard !Task.isCancelled else { return }
            progress = value; maintenance = policy
            if !hasLoadedMode {
                if policy?.isEnabled == true || value?.isMaintenanceTask == true { mode = .maintenance }
                hasLoadedMode = true
            }
        } catch is CancellationError { }
        catch { if !Task.isCancelled { errorMessage = store.iCloudErrorMessage(error) } }
    }
}
