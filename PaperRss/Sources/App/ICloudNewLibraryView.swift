import SwiftUI
#if SWIFT_PACKAGE
import PaperRssCore
#endif

struct ICloudNewLibraryView: View {
    @ObservedObject var store: AppStore
    let accountID: String
    @Environment(\.dismiss) private var dismiss
    @State private var review: ICloudNewLibraryReview?
    @State private var newLibraryConfirmed = false
    @State private var oldCloudRetentionConfirmed = false
    @State private var isBusy = false
    @State private var isReady = false
    @State private var showArchiveRecovery = false
    @State private var errorMessage: String?
    @State private var operation: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(I18N.localized("保留旧资料并准备新云库", englishFallback: "Keep Old Data and Prepare a New Cloud Library"))
                .font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(I18N.localized("新云库从空资料开始，支持安全的云端历史清理。旧云资料区继续保留并占用 iCloud 空间；旧版本设备的同步将暂停，需要各自核验并恢复当前云库。", englishFallback: "The replacement cloud library starts empty and supports safe cloud history cleanup. Previous cloud zones remain and use iCloud storage. Sync on devices using older versions will pause; each device must verify and restore the current library."))
                    Text(I18N.localized("完成云库准备后，先确认保留旧本机资料的只读归档，再接入新云库。订阅、收藏和正文通过另行选择与隐私审阅复制；本机 AI 产物留在归档。", englishFallback: "After preparing the cloud library, confirm retaining a read-only archive of old local data before adopting the new library. Subscriptions, stars and content are copied through a separate selection and privacy review. Local AI results stay in the archive."))
                        .foregroundStyle(.secondary)
                    if let review {
                        Divider()
                        Text(I18N.shared.localizedFormat("当前本机范围：订阅 %lld，文章 %lld，收藏 %lld。", review.localFeeds, review.localArticles, review.localStarredArticles))
                        if review.resumesApprovedOperation {
                            Text(I18N.localized("将继续之前已批准的新云库准备，沿用原操作及保留旧云资料的选择。", englishFallback: "Continue the previously approved preparation using its original operation and choice to retain old cloud data."))
                        } else {
                            Toggle(I18N.localized("我确认建立空的新云库，并已了解其他设备的同步与历史恢复影响。", englishFallback: "I approve creating an empty replacement cloud library and understand the sync and history recovery effects on other devices."), isOn: $newLibraryConfirmed)
                                .accessibilityIdentifier("icloud.newLibraryConfirmReplacement")
                            Toggle(I18N.localized("我确认旧云资料继续保留，占用空间并需要另行处理。", englishFallback: "I approve retaining old cloud data, its storage usage and handling it separately later."), isOn: $oldCloudRetentionConfirmed)
                                .accessibilityIdentifier("icloud.newLibraryConfirmRetention")
                        }
                    }
                    if isReady {
                        Label(I18N.localized("新云库已准备，旧本机范围保持保留。下一步核验只读归档与恢复。", englishFallback: "The new cloud library is prepared and the old local scope is retained. Next, review the read-only archive and recovery."), systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                    }
                    if isBusy { ProgressView().controlSize(.small) }
                    if let errorMessage { Text(errorMessage).foregroundStyle(.orange) }
                    Text(I18N.localized("核验阶段只读取控制信息。正式开始后会更新云库控制记录并建立空资料区；停止或关闭窗口不会撤销已完成的云端步骤，可再次核验并继续原操作。", englishFallback: "Verification only reads control metadata. Starting updates cloud control records and creates empty zones. Stopping or closing this window does not undo completed cloud steps. Verify again to continue the original operation."))
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if isReady {
                    Button(I18N.localized("核验归档与恢复…", englishFallback: "Review Archive and Recovery…")) { showArchiveRecovery = true }
                        .accessibilityIdentifier("icloud.newLibraryArchiveRecovery")
                } else if let review {
                    Button(review.resumesApprovedOperation
                        ? I18N.localized("继续已批准的准备", englishFallback: "Continue Approved Preparation")
                        : I18N.localized("开始准备新云库", englishFallback: "Prepare the New Cloud Library"), role: .destructive) {
                        run {
                            try await store.executeICloudNewLibraryReview(accountID: accountID, reviewID: review.id,
                                newLibraryConfirmed: newLibraryConfirmed, oldCloudRetentionConfirmed: oldCloudRetentionConfirmed)
                            self.review = nil; isReady = true
                        }
                    }
                    .disabled(isBusy || (!review.resumesApprovedOperation && (!newLibraryConfirmed || !oldCloudRetentionConfirmed)))
                    .accessibilityIdentifier("icloud.newLibraryStart")
                } else {
                    Button(I18N.localized("核验当前云库", englishFallback: "Verify the Current Cloud Library")) {
                        run {
                            let value = try await store.prepareICloudNewLibraryReview(accountID: accountID)
                            guard !Task.isCancelled else {
                                await store.discardICloudNewLibraryReview(accountID: accountID, id: value.id); return
                            }
                            review = value; newLibraryConfirmed = false; oldCloudRetentionConfirmed = false
                        }
                    }
                    .disabled(isBusy)
                    .accessibilityIdentifier("icloud.newLibraryPrepare")
                }
                Spacer()
                if isBusy {
                    Button(I18N.localized("停止", englishFallback: "Stop")) { operation?.cancel() }
                }
                Button(I18N.localized("完成", englishFallback: "Done")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 420, maxHeight: 660)
        .sheet(isPresented: $showArchiveRecovery) { ICloudArchiveRecoveryView(store: store, accountID: accountID) }
        .onDisappear {
            operation?.cancel()
            if let review { Task { await store.discardICloudNewLibraryReview(accountID: accountID, id: review.id) } }
        }
        .accessibilityIdentifier("icloud.newLibrarySheet")
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true; errorMessage = nil
        operation = Task {
            defer { isBusy = false }
            do { try await action() }
            catch is CancellationError { review = nil }
            catch { if !Task.isCancelled { review = nil; errorMessage = store.iCloudErrorMessage(error) } }
        }
    }
}
