import SwiftUI
#if SWIFT_PACKAGE
import PaperRssCore
#endif

struct ICloudSameAccountResumeView: View {
    @ObservedObject var store: AppStore
    let accountID: String
    @Environment(\.dismiss) private var dismiss
    @State private var review: ICloudRecoveryReview?
    @State private var result: ICloudSameAccountResumeResult?
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var showConfirmation = false
    @State private var revision = 0
    @State private var work: Work = .load(0)
    private enum Work: Equatable {
        case load(Int), resume(UUID)
        var isResume: Bool { if case .resume = self { true } else { false } }
    }
    private struct TaskID: Equatable { let account: String; let work: Work }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(I18N.localized("恢复原账号同步", englishFallback: "Resume the Original Account’s Sync")).font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(I18N.localized("请先在系统设置中切回原 iCloud 账号。此入口只恢复同一账号、同一云库代次的同步，本机缓存和待发送记录保留。", englishFallback: "Switch back to the original iCloud account in System Settings first. This action resumes sync only for the same account and cloud library generation, retaining cached data and pending changes."))
                    Text(I18N.localized("打开本页只读取本机统计。确认后会连接原账号核验云端控制信息和资料区，再恢复普通同步，继续上传原账号中允许同步的待办资料。", englishFallback: "Opening this page only reads local counts. After confirmation, it connects to the original account to verify cloud control metadata and zones, then resumes normal sync and eligible pending uploads for that account."))
                        .foregroundStyle(.secondary)
                    if let result {
                        completion(result)
                    } else if let review {
                        Text(I18N.shared.localizedFormat("本机保留订阅 %lld，目录 %lld，文章 %lld，收藏 %lld。", review.feeds, review.folders, review.articles, review.starredArticles))
                        if !review.canResumeOriginalAccount {
                            Text(I18N.localized("当前状态不适用原账号恢复。换账号、新代次、缺失资料区或重置的恢复方式需要另行确认。", englishFallback: "The current state is not eligible for original-account recovery. Account changes, new generations, missing zones or resets need a separate recovery review."))
                                .foregroundStyle(.orange)
                        }
                    }
                    if !store.supportsICloudSync {
                        Text(I18N.localized("此版本尚未配置 iCloud 同步，仍可查看本机资料。", englishFallback: "This build is not configured for iCloud sync. Local data can still be reviewed.")).foregroundStyle(.orange)
                    }
                    if isBusy {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(work.isResume ? I18N.localized("正在核验原账号并尝试恢复同步…", englishFallback: "Verifying the original account and attempting to resume sync…") : I18N.localized("正在读取本机资料…", englishFallback: "Reading local data…"))
                        }
                    }
                    if let errorMessage { Text(errorMessage).foregroundStyle(.orange) }
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button(I18N.localized("重新核对本机状态", englishFallback: "Review Local State Again")) {
                    review = nil; result = nil; revision += 1; work = .load(revision)
                }.disabled(isBusy)
                Spacer()
                if result == nil {
                    Button(I18N.localized("核验并恢复原账号同步…", englishFallback: "Verify and Resume the Original Account’s Sync…")) { showConfirmation = true }
                        .disabled(isBusy || review?.canResumeOriginalAccount != true || !store.supportsICloudSync)
                        .accessibilityIdentifier("icloud.confirmOriginalAccountResume")
                }
                Button(I18N.localized("完成", englishFallback: "Done")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 540, minHeight: 400, maxHeight: 650)
        .task(id: TaskID(account: accountID, work: work)) { await run(work) }
        .alert(I18N.localized("恢复原账号的同步？", englishFallback: "Resume sync for the original account?"), isPresented: $showConfirmation) {
            Button(I18N.localized("取消", englishFallback: "Cancel"), role: .cancel) {}
            Button(I18N.localized("确认核验并恢复", englishFallback: "Confirm Verification and Resume")) { work = .resume(UUID()) }
        } message: {
            Text(I18N.localized("只有系统账号、云库代次和资料区核验一致时才解除暂停。恢复后，原账号的待发送资料将继续同步到该账号的私有云库。", englishFallback: "Sync is unpaused only when the system account, cloud generation and zones are verified as matching. Pending data for the original account then continues syncing to that account’s private cloud library."))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("icloud.originalAccountResumeSheet")
    }

    private func completion(_ result: ICloudSameAccountResumeResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(result.isPaused ? I18N.localized("同步状态仍需核对，本机资料已保留。", englishFallback: "Sync status still needs review. Local data is retained.") : I18N.localized("原账号核验已通过，已请求恢复普通同步。", englishFallback: "The original account was verified and normal sync has been requested."))
                .font(.headline)
            Text(I18N.localized("请在账号设置查看后续进度。恢复请求完成不代表所有待办已保存到云端。", englishFallback: "Check further progress in account settings. A completed resume request does not mean all pending data is saved in the cloud."))
                .foregroundStyle(.secondary)
            if let warning = result.syncWarning { Text(warning).foregroundStyle(.orange) }
        }
    }

    private func run(_ request: Work) async {
        isBusy = true; errorMessage = nil
        defer { isBusy = false }
        do {
            switch request {
            case .load:
                let loaded = try await store.iCloudRecoveryReview(accountID: accountID)
                if !Task.isCancelled { review = loaded }
            case .resume:
                let resumed = try await store.resumeOriginalICloudAccount(accountID: accountID, confirmed: true)
                if !Task.isCancelled { result = resumed }
            }
        } catch is CancellationError {}
        catch { if !Task.isCancelled { errorMessage = store.iCloudErrorMessage(error) } }
    }
}
