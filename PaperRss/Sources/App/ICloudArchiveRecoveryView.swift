import SwiftUI
#if SWIFT_PACKAGE
import PaperRssCore
#endif

struct ICloudArchiveRecoveryView: View {
    @ObservedObject var store: AppStore
    let accountID: String
    @Environment(\.dismiss) private var dismiss
    @State private var counts: ICloudArchiveReview?
    @State private var canRecover = false
    @State private var prepared: ICloudArchiveRecoveryReview?
    @State private var result: ICloudArchiveRecoveryResult?
    @State private var hasReviewed = false
    @State private var hasReviewedInitialization = false
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var confirmation: Confirmation?
    @State private var revision = 0
    @State private var work: Work = .load(0)

    private enum Work: Equatable { case load(Int), prepare(UUID), execute(UUID, Bool) }
    private enum Confirmation: String, Identifiable {
        case connect, archive
        var id: String { rawValue }
    }
    private struct TaskID: Equatable { let account: String; let work: Work }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(I18N.localized("保留归档并恢复当前云库", englishFallback: "Keep an Archive and Restore the Current Cloud Library"))
                .font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(I18N.localized("旧文章、收藏和本机 AI 结果将留在只读归档中，停止刷新与同步。当前系统 iCloud 账号使用独立的新同步范围。", englishFallback: "Old articles, stars and local AI results stay in a read-only archive with refresh and sync stopped. The current system iCloud account uses a separate, new sync scope."))
                    Text(I18N.localized("打开本页只读取本机资料。连接核验只读取当前云库的控制信息和资料区；之后还需要单独确认归档。", englishFallback: "Opening this page only reads local data. Connection verification only reads the current cloud library’s control metadata and zones. Archival requires a separate confirmation afterward."))
                        .foregroundStyle(.secondary)
                    if let counts { localCounts(counts) }
                    if let result {
                        completion(result)
                    } else if let prepared {
                        Text(I18N.localized("当前云库已完成核验。确认时会再次核验；资料变化或超过十分钟需要重新核对。", englishFallback: "The current cloud library has been verified. Confirmation verifies it again; changed data or a review older than ten minutes requires a new review."))
                        if prepared.needsCloudInitialization {
                            Text(I18N.localized("当前 iCloud 未发现 PaperRss 云库或旧版资料。确认后将建立新的空云库；旧归档仍保留在本机。", englishFallback: "No PaperRss cloud library or legacy data was found in the current iCloud account. Confirmation creates a new empty library; the old archive stays on this Mac."))
                            Toggle(I18N.localized("我确认建立新的空 iCloud 云库", englishFallback: "I confirm creating a new empty iCloud library"), isOn: $hasReviewedInitialization)
                                .disabled(isBusy)
                                .accessibilityIdentifier("icloud.archiveInitializeReviewed")
                        }
                        Text(I18N.localized("旧资料不会自动复制到当前 iCloud。若需要带回订阅或收藏，必须另行选择资料并审阅订阅地址、原始 GUID 和 RSS 正文中的私人信息。", englishFallback: "Old data is not automatically copied to the current iCloud account. Bringing back feeds or stars requires a separate selection and review of private information in feed addresses, original GUIDs and RSS content."))
                            .foregroundStyle(.secondary)
                        Toggle(I18N.localized("我已核对资料数量，确认保留旧库为只读归档", englishFallback: "I have reviewed the counts and want to keep the old library as a read-only archive"), isOn: $hasReviewed)
                            .disabled(isBusy)
                            .accessibilityIdentifier("icloud.archiveReviewed")
                        Text(prepared.preparedAt, format: .dateTime.year().month().day().hour().minute())
                            .font(.caption).foregroundStyle(.secondary)
                    } else if !isBusy, !canRecover {
                        Text(I18N.localized("当前本机状态不适用此恢复方式。原账号同代次请使用“恢复原账号同步”；无法核实或资料区不完整的云库需要另行处理。", englishFallback: "The current local state is not eligible for this recovery. For the original account and generation, use Resume the Original Account’s Sync. Unverified or incomplete cloud libraries need separate recovery."))
                            .foregroundStyle(.orange)
                    }
                    if !store.supportsICloudSync {
                        Text(I18N.localized("此版本尚未配置 iCloud 同步，仍可查看本机资料。", englishFallback: "This build is not configured for iCloud sync. Local data can still be reviewed."))
                            .foregroundStyle(.orange)
                    }
                    if isBusy {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(progressMessage)
                        }
                    }
                    if let errorMessage { Text(errorMessage).foregroundStyle(.orange) }
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if result == nil {
                    Button(I18N.localized("重新核对本机状态", englishFallback: "Review Local State Again")) {
                        revision += 1; work = .load(revision)
                    }.disabled(isBusy)
                }
                Spacer()
                if result == nil {
                    if let prepared {
                        Button(I18N.localized("确认归档并恢复…", englishFallback: "Confirm Archive and Restore…")) { confirmation = .archive }
                            .disabled(isBusy || !hasReviewed || (prepared.needsCloudInitialization && !hasReviewedInitialization) || !store.supportsICloudSync)
                            .accessibilityIdentifier("icloud.confirmArchiveRecovery")
                    } else {
                        Button(I18N.localized("连接并核验当前云库…", englishFallback: "Connect and Verify the Current Cloud Library…")) { confirmation = .connect }
                            .disabled(isBusy || !canRecover || counts == nil || !store.supportsICloudSync)
                            .accessibilityIdentifier("icloud.prepareArchiveRecovery")
                    }
                }
                Button(I18N.localized("完成", englishFallback: "Done")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 580, minHeight: 420, maxHeight: 680)
        .task(id: TaskID(account: accountID, work: work)) { await run(work) }
        .alert(confirmationTitle, isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
            Button(I18N.localized("取消", englishFallback: "Cancel"), role: .cancel) {}
            if confirmation == .connect {
                Button(I18N.localized("确认连接并核验", englishFallback: "Confirm Connection and Verification")) { work = .prepare(UUID()) }
            } else if let prepared {
                Button(I18N.localized("确认保留归档并恢复", englishFallback: "Confirm Archive and Restore")) { work = .execute(prepared.id, hasReviewedInitialization) }
            }
        } message: { Text(confirmationMessage) }
        .onDisappear {
            if let prepared { Task { await store.discardICloudArchiveRecoveryReview(id: prepared.id) } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("icloud.archiveRecoverySheet")
    }

    private var progressMessage: String {
        switch work {
        case .load: I18N.localized("正在读取本机资料…", englishFallback: "Reading local data…")
        case .prepare: I18N.localized("正在核验当前云库…", englishFallback: "Verifying the current cloud library…")
        case .execute: I18N.localized("正在保留归档并恢复当前云库…", englishFallback: "Keeping the archive and restoring the current cloud library…")
        }
    }

    private var confirmationTitle: String {
        if confirmation == .connect {
            return I18N.localized("连接当前系统 iCloud 账号？", englishFallback: "Connect to the current system iCloud account?")
        }
        if prepared?.needsCloudInitialization == true {
            return I18N.localized("保留只读归档并建立新的空云库？", englishFallback: "Keep a read-only archive and create a new empty cloud library?")
        }
        return I18N.localized("保留只读归档并恢复当前云库？", englishFallback: "Keep a read-only archive and restore the current cloud library?")
    }

    private var confirmationMessage: String {
        if confirmation == .connect {
            return I18N.localized("将停止旧账号的自动同步，读取当前系统账号的云端控制信息和资料区进行核验。此步骤不会归档、复制或删除旧资料。", englishFallback: "This stops automatic sync for the old account and reads the current system account’s cloud control metadata and zones for verification. This step does not archive, copy or delete old data.")
        }
        if prepared?.needsCloudInitialization == true {
            return I18N.localized("旧库将原位保留为只读归档，停止刷新与同步。随后在当前 iCloud 建立新的空云库并进行普通同步。旧资料需要另行选择复制，本次不删除资料。", englishFallback: "The old library stays in place as a read-only archive with refresh and sync stopped. A new empty library is then created in the current iCloud account with normal sync. Copying old data requires a separate selection. No data is deleted by this action.")
        }
        return I18N.localized("旧库将原位保留为只读归档，停止刷新与同步。随后在新范围恢复当前云库并进行普通同步；旧资料不会自动上传。此操作不删除本机或云端资料。", englishFallback: "The old library stays in place as a read-only archive with refresh and sync stopped. The current cloud library is then restored in a new scope with normal sync; old data is not automatically uploaded. This does not delete local or cloud data.")
    }

    private func localCounts(_ value: ICloudArchiveReview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(I18N.shared.localizedFormat("本机保留订阅 %lld，目录 %lld，文章 %lld，收藏 %lld。", value.feeds, value.folders, value.articles, value.starredArticles))
            Text(I18N.shared.localizedFormat("归档保留缺少身份的文章 %lld，本机 AI 产物 %lld。", value.missingIdentities, value.aiArtifacts))
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("icloud.archiveLocalCounts")
    }

    private func completion(_ value: ICloudArchiveRecoveryResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(I18N.localized("旧库已保留为只读归档，当前云库已建立独立同步范围。", englishFallback: "The old library is retained as a read-only archive. The current cloud library has a separate sync scope."))
                .font(.headline)
            Text(I18N.localized("请在账号设置查看后续同步进度。恢复完成不代表云端资料已全部下载或待办已全部上传。", englishFallback: "Check subsequent sync progress in account settings. Recovery does not mean that all cloud data has downloaded or all pending changes have uploaded."))
                .foregroundStyle(.secondary)
            if let warning = value.syncWarning { Text(warning).foregroundStyle(.orange) }
        }
    }

    private func run(_ request: Work) async {
        isBusy = true; errorMessage = nil
        defer { if work == request { isBusy = false } }
        do {
            switch request {
            case .load:
                if let prepared { await store.discardICloudArchiveRecoveryReview(id: prepared.id) }
                prepared = nil; counts = nil; hasReviewed = false; hasReviewedInitialization = false; canRecover = false
                let recovery = try await store.iCloudRecoveryReview(accountID: accountID)
                guard !Task.isCancelled else { return }
                if recovery.canArchiveAndRecover {
                    let loaded = try await store.iCloudArchiveLocalReview(accountID: accountID)
                    guard !Task.isCancelled else { return }
                    counts = loaded; canRecover = true
                }
            case .prepare:
                hasReviewed = false; hasReviewedInitialization = false
                let review = try await store.prepareICloudArchiveRecovery(accountID: accountID, connectionConfirmed: true)
                guard !Task.isCancelled else {
                    await store.discardICloudArchiveRecoveryReview(id: review.id)
                    return
                }
                counts = review.counts; prepared = review
            case .execute(let id, let initializeConfirmed):
                prepared = nil; hasReviewed = false; hasReviewedInitialization = false
                let recovered = try await store.executeICloudArchiveRecovery(reviewID: id, archiveConfirmed: true,
                    initializeEmptyCloudConfirmed: initializeConfirmed)
                if !Task.isCancelled { result = recovered }
            }
        } catch is CancellationError {}
        catch { if !Task.isCancelled { errorMessage = store.iCloudErrorMessage(error) } }
    }
}
