import SwiftUI
#if SWIFT_PACKAGE
import PaperRssCore
#endif

struct ICloudLocalCopyView: View {
    @ObservedObject var store: AppStore
    let sourceAccountID: String
    @Environment(\.dismiss) private var dismiss
    @State private var catalog: ICloudCopySourceCatalog?
    @State private var feedIDs: Set<String> = []
    @State private var folderIDs: Set<String> = []
    @State private var reviewedLinkIDs: Set<String> = []
    @State private var includeArticles = true
    @State private var review: ICloudCopyReview?
    @State private var result: ICloudCopyResult?
    @State private var privacyReviewed = false
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var showConfirmation = false
    @State private var revision = 0
    @State private var work: Work = .load(0)

    private enum Work: Equatable {
        case load(Int), prepare(ICloudCopySelection, Int), copy(UUID)
    }
    private struct TaskIdentity: Equatable { let source: String; let work: Work }
    private var selection: ICloudCopySelection {
        .init(feedIDs: feedIDs, folderIDs: folderIDs, includeReliableArticles: includeArticles,
              reviewedLinkIDs: reviewedLinkIDs.intersection(feedIDs))
    }
    private var selectionCount: Int { feedIDs.count + folderIDs.count }
    private var sourceIsArchive: Bool {
        catalog?.sourceIsArchive ?? store.accounts.contains { $0.id == sourceAccountID && $0.isArchived }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(sourceIsArchive ? I18N.localized("复制归档资料到当前 iCloud", englishFallback: "Copy Archived Data to the Current iCloud Account") : I18N.localized("复制本地资料到 iCloud", englishFallback: "Copy Local Data to iCloud")).font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    explanation
                    if let result { completion(result) }
                    else if let review { reviewDetails(review) }
                    else if let catalog { sourceSelection(catalog) }
                    if isBusy {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(progressMessage).foregroundStyle(.secondary)
                        }
                    }
                    if let errorMessage { Text(errorMessage).foregroundStyle(.orange) }
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 500, maxHeight: 760)
        .task(id: TaskIdentity(source: sourceAccountID, work: work)) { await run(work) }
        .onDisappear {
            if let review { Task { await store.discardICloudLocalCopyReview(id: review.id) } }
        }
        .alert(I18N.localized("确认复制选中的资料？", englishFallback: "Copy the selected data?"), isPresented: $showConfirmation) {
            Button(I18N.localized("取消", englishFallback: "Cancel"), role: .cancel) {}
            Button(I18N.localized("确认复制", englishFallback: "Confirm Copy")) {
                if let review { work = .copy(review.id) }
            }
        } message: {
            Text(sourceIsArchive ? I18N.localized("原只读归档保留。选中资料的新副本将进入当前 iCloud 账号并等待上传，旧归档不会重新启用。", englishFallback: "The original read-only archive is retained. New copies of the selected data enter the current iCloud account and are queued for upload. The old archive is not reactivated.") : I18N.localized("原本地库保留。新增资料将进入本机 iCloud 账号并等待上传到当前系统 iCloud 用户的私有云库。", englishFallback: "The original local library is retained. New data enters the iCloud account on this Mac and is queued for the current system iCloud user’s private cloud library."))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("icloud.localCopySheet")
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 8) {
            if sourceIsArchive {
                Text(I18N.localized("只读归档原位保留。复制只新增当前云库中没有的可靠资料，AI 产物和旧同步待办仍留在归档。", englishFallback: "The read-only archive stays in place. Copying only adds reliable data absent from the current cloud library. AI results and old pending sync records stay in the archive."))
                    .foregroundStyle(.secondary)
            }
            Text(I18N.localized("先选择资料，再核验目标云库并预览。确认前不会复制本地资料；核验会刷新 iCloud 账号现有的云端资料。", englishFallback: "Choose data, then verify the target cloud library and preview. Local data is not copied before confirmation. Verification refreshes the iCloud account’s existing cloud data."))
            Text(I18N.localized("原本地库保留。目标已有订阅及其文章、同名目录和删除标记不覆盖；缺失或重复身份的文章及含凭据的订阅留在本地。", englishFallback: "The original library is retained. Existing target subscriptions and their articles, same-name folders and deletion markers are preserved. Articles with missing or duplicate identities and subscriptions containing credentials stay local."))
                .foregroundStyle(.secondary)
            if !store.canPrepareICloudLocalCopy {
                Text(I18N.localized("需要可用的 iCloud 同步版本及已启用的 iCloud 账号，才能准备复制。仍可在此审阅本地资料。", englishFallback: "Preparing a copy requires a build that supports iCloud sync and an enabled iCloud account. Local data can still be reviewed here."))
                    .foregroundStyle(.orange)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func sourceSelection(_ catalog: ICloudCopySourceCatalog) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if catalog.sourceIsArchive {
                Text(I18N.localized("来源是只读本机归档，复制不会更改归档的文章或阅读状态。", englishFallback: "The source is a read-only local archive. Copying does not change its articles or reading states."))
                    .foregroundStyle(.secondary)
            } else if !catalog.sourceIsEnabled {
                Text(I18N.localized("本地账号已停用，仍可复制已审阅的保留资料。", englishFallback: "The local account is disabled. Reviewed retained data can still be copied."))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text(I18N.shared.localizedFormat("已选择订阅 %lld，目录 %lld。", feedIDs.count, folderIDs.count))
                Spacer()
                Button(I18N.localized("选择全部可用资料", englishFallback: "Select All Available")) {
                    feedIDs = Set(catalog.feeds.filter { $0.blocked == nil && !$0.requiresLinkReview }.map(\.id))
                    folderIDs = Set(catalog.folders.filter { !$0.isDuplicateName }.map(\.id))
                }
                .disabled(isBusy)
            }
            Text(I18N.localized("每次最多选择 500 个订阅和目录。带查询参数或片段的链接需逐项审阅；检查不能识别所有路径令牌或私人信息。", englishFallback: "Select up to 500 subscriptions and folders per copy. Links with query parameters or fragments require individual review. Checks cannot identify every private path token or sensitive detail."))
                .foregroundStyle(selectionCount > 500 ? Color.orange : Color.secondary)
            Toggle(I18N.localized("同时复制身份可靠且唯一的文章与阅读状态", englishFallback: "Also Copy Articles with Reliable Unique Identities and Their Reading States"), isOn: $includeArticles)
                .disabled(isBusy)
            Text(I18N.localized("收藏的 RSS 正文会随可靠文章复制；未读正文遵循目标 iCloud 账号已有设置。AI 结果、模型配置和网页提取缓存不复制。", englishFallback: "Starred RSS bodies accompany reliable articles. Unread bodies follow the target iCloud account’s existing setting. AI results, model settings and extracted webpage caches are not copied."))
                .foregroundStyle(.secondary)
            Divider()
            Text(I18N.localized("订阅", englishFallback: "Subscriptions")).font(.headline)
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(catalog.feeds) { feed in feedRow(feed) }
            }
            Divider()
            Text(I18N.localized("目录", englishFallback: "Folders")).font(.headline)
            ForEach(catalog.folders) { folder in
                Toggle(isOn: membership(folder.id, in: $folderIDs)) {
                    HStack {
                        Text(folder.name)
                        if folder.isDuplicateName {
                            Text(I18N.localized("名称重复，保留本地", englishFallback: "Duplicate name; stays local")).foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(isBusy || folder.isDuplicateName)
            }
        }
    }

    private func feedRow(_ feed: ICloudCopySourceCatalog.Feed) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle(feed.title, isOn: membership(feed.id, in: $feedIDs))
                .disabled(isBusy || feed.blocked != nil || (feed.requiresLinkReview && !reviewedLinkIDs.contains(feed.id)))
            if let blocked = feed.blocked {
                Text(blockMessage(blocked)).font(.caption).foregroundStyle(.secondary)
            } else {
                DisclosureGroup(I18N.localized("审阅订阅与网站链接", englishFallback: "Review Subscription and Website Links")) {
                    VStack(alignment: .leading, spacing: 6) {
                        if let address = feed.address { Text(verbatim: address).textSelection(.enabled) }
                        if let address = feed.siteAddress { Text(verbatim: address).textSelection(.enabled) }
                        if feed.requiresLinkReview {
                            Toggle(I18N.localized("我已确认这些链接不含凭据或私人令牌", englishFallback: "I Confirm These Links Contain No Credentials or Private Tokens"),
                                   isOn: Binding(get: { reviewedLinkIDs.contains(feed.id) }, set: { checked in
                                       if checked { reviewedLinkIDs.insert(feed.id) }
                                       else { reviewedLinkIDs.remove(feed.id); feedIDs.remove(feed.id) }
                                   }))
                                   .disabled(isBusy)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .disabled(isBusy)
            }
        }
        .accessibilityIdentifier("icloud.copyFeed.\(feed.id)")
    }

    private func reviewDetails(_ review: ICloudCopyReview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(I18N.localized("复制范围已核验", englishFallback: "Copy Range Verified")).font(.headline)
            counts(review.counts)
            Text(I18N.localized("确认时会再次核验账号、云端代次与资料。资料改变或预览超过十分钟需重新选择并预览。", englishFallback: "Confirmation rechecks the account, cloud generation and data. Changes or a preview older than ten minutes require a new selection and preview."))
                .foregroundStyle(.secondary)
            Text(I18N.localized("订阅与网站链接、原始条目标识及允许复制的 RSS 正文可能包含私人信息。请审阅选中的资料；本流程不检查全部正文或标识中的秘密。", englishFallback: "Subscription and website links, original item identities and eligible RSS bodies may contain private information. Review the selected data; this flow does not detect every secret in content or identities."))
                .foregroundStyle(.secondary)
            Toggle(I18N.localized("我已审阅选中的资料，并同意按此范围同步到我的 iCloud 私有云库", englishFallback: "I Have Reviewed the Selected Data and Agree to Sync This Range to My Private iCloud Library"), isOn: $privacyReviewed)
                .disabled(isBusy || !review.counts.hasCopies)
            if !review.counts.hasCopies {
                Text(I18N.localized("此范围没有可新增的资料，请重新选择。", englishFallback: "This range has no new data to copy. Choose another range.")).foregroundStyle(.orange)
            }
        }
        .accessibilityIdentifier("icloud.copyReview")
    }

    private func completion(_ result: ICloudCopyResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(I18N.localized("本机复制已完成", englishFallback: "Local Copy Complete")).font(.headline)
            counts(result.counts)
            Text(I18N.localized("资料已进入本机 iCloud 账号并保留待发送记录。请在 iCloud 账号设置查看同步进度；本机复制完成不代表云端已全部保存。", englishFallback: "Data is now in the iCloud account on this Mac with durable pending changes. Check sync progress in iCloud account settings. Local copy completion does not mean all data is saved in the cloud."))
                .foregroundStyle(.secondary)
            if let warning = result.syncWarning { Text(warning).foregroundStyle(.orange) }
        }
        .accessibilityIdentifier("icloud.copyComplete")
    }

    private func counts(_ value: ICloudCopyCounts) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(I18N.shared.localizedFormat("新增订阅 %lld，目录 %lld，目录关系 %lld。", value.feeds, value.folders, value.relationships))
            Text(I18N.shared.localizedFormat("可靠文章与状态 %lld，RSS 正文缓存 %lld，超限正文保留本地 %lld。", value.articles, value.rssBodies, value.omittedRSSBodies))
            Text(I18N.shared.localizedFormat("跳过订阅 %lld，目录 %lld，文章 %lld。", value.skippedFeeds, value.skippedFolders, value.skippedArticles)).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            if result == nil {
                Button(I18N.localized("重新选择", englishFallback: "Choose Again")) { reload() }.disabled(isBusy)
                Spacer()
                if let review {
                    Button(I18N.localized("复制到 iCloud 账号…", englishFallback: "Copy to iCloud Account…")) { showConfirmation = true }
                        .disabled(isBusy || !privacyReviewed || !review.counts.hasCopies || !store.canPrepareICloudLocalCopy)
                        .accessibilityIdentifier("icloud.confirmLocalCopy")
                } else {
                    Button(I18N.localized("核验云库并预览", englishFallback: "Verify Cloud Library and Preview")) {
                        revision += 1; work = .prepare(selection, revision)
                    }
                    .disabled(isBusy || catalog == nil || selectionCount == 0 || selectionCount > 500 || !store.canPrepareICloudLocalCopy)
                    .accessibilityIdentifier("icloud.prepareLocalCopy")
                }
            } else { Spacer() }
            Button(I18N.localized("完成", englishFallback: "Done")) { dismiss() }.keyboardShortcut(.cancelAction)
        }
    }

    private var progressMessage: String {
        switch work {
        case .load: I18N.localized("正在读取本机资料…", englishFallback: "Reading local data…")
        case .prepare: I18N.localized("正在恢复并核验目标云库…", englishFallback: "Restoring and Verifying the Target Cloud Library…")
        case .copy: I18N.localized("正在复核并提交本机复制…", englishFallback: "Rechecking and Committing the Local Copy…")
        }
    }
    private func membership(_ id: String, in values: Binding<Set<String>>) -> Binding<Bool> {
        .init(get: { values.wrappedValue.contains(id) }, set: { checked in
            if checked { values.wrappedValue.insert(id) } else { values.wrappedValue.remove(id) }
        })
    }
    private func blockMessage(_ reason: ICloudCopySourceCatalog.Feed.Block) -> String {
        switch reason {
        case .credentials: I18N.localized("链接包含凭据，保留本地", englishFallback: "Link contains credentials; stays local")
        case .invalidURL: I18N.localized("订阅或网站链接无法核实，保留本地", englishFallback: "Subscription or website link cannot be verified; stays local")
        case .duplicateIdentity: I18N.localized("订阅身份重复，保留本地", englishFallback: "Duplicate subscription identity; stays local")
        }
    }
    private func reload() {
        if let review { Task { await store.discardICloudLocalCopyReview(id: review.id) } }
        review = nil; privacyReviewed = false; reviewedLinkIDs = []; errorMessage = nil
        revision += 1; work = .load(revision)
    }
    private func run(_ request: Work) async {
        isBusy = true; errorMessage = nil
        defer { isBusy = false }
        do {
            switch request {
            case .load:
                let loaded = try await store.iCloudCopySourceCatalog(sourceAccountID: sourceAccountID)
                guard !Task.isCancelled else { return }
                catalog = loaded
                feedIDs.formIntersection(Set(loaded.feeds.filter { $0.blocked == nil && !$0.requiresLinkReview }.map(\.id)))
                folderIDs.formIntersection(Set(loaded.folders.filter { !$0.isDuplicateName }.map(\.id)))
            case .prepare(let selection, _):
                guard let catalog else { return }
                let prepared = try await store.prepareICloudLocalCopy(catalog: catalog, selection: selection)
                guard !Task.isCancelled else { await store.discardICloudLocalCopyReview(id: prepared.id); return }
                review = prepared; privacyReviewed = false
            case .copy(let id):
                let copied = try await store.executeICloudLocalCopy(reviewID: id, privacyReviewed: privacyReviewed)
                guard !Task.isCancelled else { return }
                result = copied; review = nil
            }
        } catch is CancellationError {}
        catch {
            if !Task.isCancelled {
                errorMessage = store.iCloudErrorMessage(error)
                if case .copy = request { review = nil; privacyReviewed = false }
            }
        }
    }
}
