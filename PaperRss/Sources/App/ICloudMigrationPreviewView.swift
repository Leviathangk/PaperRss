import SwiftUI
#if SWIFT_PACKAGE
import PaperRssCore
#endif

struct ICloudMigrationPreviewView: View {
    @ObservedObject var store: AppStore
    let sourceAccountID: String
    @Environment(\.dismiss) private var dismiss
    @State private var preview: ICloudMigrationPreview?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var revision = 0

    private struct LoadIdentity: Equatable {
        let source: String
        let revision: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(I18N.localized("本地资料同步预览", englishFallback: "Local Data Sync Preview"))
                .font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(I18N.localized("只检查本地账号与 iCloud 账号在本机的资料。不连接网络，不复制、上传、合并或删除资料。", englishFallback: "Reviews the local account and the iCloud account’s data cached on this Mac. It does not connect to the network or copy, upload, merge or delete data."))
                        .foregroundStyle(.secondary)
                    if let preview {
                        sourceData(preview)
                        Divider()
                        identities(preview)
                        Divider()
                        linkRisks(preview)
                        Divider()
                        targetData(preview)
                        HStack {
                            Text(I18N.localized("统计时间", englishFallback: "Counted at"))
                            Text(preview.scannedAt, format: .dateTime.year().month().day().hour().minute())
                        }
                        .foregroundStyle(.secondary)
                    }
                    if isLoading {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(I18N.localized("正在读取本机资料…", englishFallback: "Reading local data…"))
                        }
                    }
                    if let errorMessage { Text(errorMessage).foregroundStyle(.orange) }
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button(I18N.localized("重新统计", englishFallback: "Rescan")) { revision += 1 }
                    .disabled(isLoading)
                Spacer()
                Button(I18N.localized("完成", englishFallback: "Done")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 440, maxHeight: 700)
        .task(id: LoadIdentity(source: sourceAccountID, revision: revision)) { await load() }
        .accessibilityIdentifier("icloud.localMigrationPreviewSheet")
    }

    private func sourceData(_ value: ICloudMigrationPreview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(I18N.localized("当前本地资料", englishFallback: "Current Local Data")).font(.headline)
            if !value.sourceIsEnabled {
                Text(I18N.localized("本地账号已停用，仍可查看保留的资料。", englishFallback: "The local account is disabled. Retained data is still available for review."))
                    .foregroundStyle(.secondary)
            }
            Text(I18N.shared.localizedFormat("订阅 %lld，目录 %lld，本机文章 %lld。", value.feeds, value.folders, value.articles))
            Text(I18N.shared.localizedFormat("已读文章 %lld，收藏文章 %lld。", value.readArticles, value.starredArticles))
            Text(I18N.shared.localizedFormat("目录关系 %lld，多目录订阅 %lld，重复目录名称 %lld 组。",
                value.folderRelationships, value.feedsInMultipleFolders, value.duplicateFolderNameGroups))
            Text(I18N.localized("统计只包括这个本地账号的未删除订阅和目录。复制范围与目录合并方式仍需确认。", englishFallback: "Counts include this local account’s active subscriptions and folders. Copy scope and folder merging need review."))
                .foregroundStyle(.secondary)
        }
    }

    private func identities(_ value: ICloudMigrationPreview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(I18N.localized("历史资料身份", englishFallback: "Historical Data Identities")).font(.headline)
            Text(I18N.shared.localizedFormat("身份稳定且无本机重复的文章 %lld，其中收藏 %lld。",
                value.articlesWithStableUniqueIdentity, value.starredWithStableUniqueIdentity))
            Text(I18N.shared.localizedFormat("带 RSS 正文缓存且身份可对应的收藏：%lld。", value.starredWithRSSBodyAndStableIdentity))
            Text(I18N.shared.localizedFormat("缺少原始身份的文章：%lld，其中收藏 %lld。", value.missingIdentities, value.starredMissingIdentities))
            Text(I18N.shared.localizedFormat("重复订阅身份 %lld 组，重复文章身份 %lld 组，缺少阅读状态 %lld 篇。",
                value.duplicateFeedIdentityGroups, value.duplicateArticleIdentityGroups, value.missingReadingStates))
            Text(I18N.localized("地址格式不同也可能对应同一订阅。重复、缺失身份和缺少状态的资料暂不作可对应判断；不按标题或本地编号猜测身份。正文数量不代表每篇都符合格式和大小限制。", englishFallback: "Different URL spellings may identify the same subscription. Duplicates, missing identities and missing states are excluded from stable identity counts. Titles and local IDs are not used to guess identities. Body counts do not guarantee format or size eligibility."))
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("icloud.migrationIdentityPreview")
    }

    private func linkRisks(_ value: ICloudMigrationPreview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(I18N.localized("订阅链接检查", englishFallback: "Subscription Link Review")).font(.headline)
            Text(I18N.shared.localizedFormat("需要检查的订阅链接：%lld。", value.flaggedFeedLinks))
            Text(I18N.shared.localizedFormat("包含账号信息 %lld，查询参数 %lld，片段 %lld，无法核实 %lld。",
                value.feedLinksWithCredentials, value.feedLinksWithQuery, value.feedLinksWithFragment, value.unverifiableFeedLinks))
            Text(I18N.localized("同一链接可能计入多类。查询参数不一定是凭据，路径中也可能包含私人令牌；此检查不能识别所有敏感内容。", englishFallback: "A link can appear in several categories. Query parameters may be harmless, while paths may contain private tokens. This check cannot identify all sensitive content."))
                .foregroundStyle(.secondary)
            Text(I18N.localized("完整订阅地址、原始条目身份和允许同步的 RSS 正文可能携带私人信息。复制前需确认处理方式；预览不显示完整地址，不移除参数，也不改写订阅。", englishFallback: "Full subscription URLs, original item identities and eligible RSS content may contain private information. Review their handling before copying. This preview does not show full URLs, remove parameters or rewrite subscriptions."))
                .foregroundStyle(.secondary)
        }
    }

    private func targetData(_ value: ICloudMigrationPreview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(I18N.localized("目标账号的本机观察", englishFallback: "Local Observations of the Target Account")).font(.headline)
            Text(targetMessage(value.targetStatus)).foregroundStyle(.secondary)
            Text(I18N.shared.localizedFormat("目标本机订阅 %lld，已观察到的重叠订阅 %lld，涉及删除标记 %lld。",
                value.targetFeeds, value.feedsAlreadyObservedInTarget, value.feedsWithTargetDeletion))
            Text(I18N.shared.localizedFormat("重叠目录名称 %lld，重叠文章身份 %lld，已读分歧 %lld，收藏分歧 %lld。",
                value.folderNamesAlreadyInTarget, value.articlesAlreadyObservedInTarget,
                value.observedReadDisagreements, value.observedStarDisagreements))
            if value.targetEntriesRequiringReview > 0 {
                Text(I18N.shared.localizedFormat("目标本机缓存中有 %lld 条资料需要核实。", value.targetEntriesRequiringReview))
                    .foregroundStyle(.orange)
            }
            Text(I18N.localized("这些计数来自本机条目、待发送更改和已接收缓存，可能含新旧状态分歧；不代表云端已完整恢复或为空。涉及目标删除标记的订阅不能直接恢复，复制和冲突处理仍待确认。", englishFallback: "Counts come from local items, pending changes and received cache and may include differing old and new states. They do not prove complete cloud recovery or an empty cloud library. Subscriptions with target deletion markers cannot be restored directly. Copying and conflict handling need review."))
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("icloud.migrationTargetPreview")
    }

    private func targetMessage(_ status: ICloudMigrationPreview.TargetStatus) -> String {
        switch status {
        case .notCreated:
            return I18N.localized("本机尚未添加 iCloud 账号。预览不会自动创建账号。", englishFallback: "No iCloud account has been added on this Mac. The preview does not create one.")
        case .disabled:
            return I18N.localized("本机 iCloud 账号已停用，本次仅查看其本机缓存。", englishFallback: "The iCloud account is disabled. This review only inspects its local cache.")
        case .requiresReview:
            return I18N.localized("本机 iCloud 账号已暂停或保留重置确认，需要先确认恢复方式。", englishFallback: "The iCloud account is paused or retains reset approval. Recovery needs review first.")
        case .notInitialized:
            return I18N.localized("本机尚未确认 iCloud 同步绑定，云端资料情况仍需核实。", englishFallback: "This Mac has not confirmed its iCloud sync binding. Cloud data still needs verification.")
        case .locallyBound:
            return I18N.localized("本机已有 iCloud 同步绑定，云端恢复情况仍需核实。", englishFallback: "An iCloud sync binding exists locally. Cloud recovery still needs verification.")
        }
    }

    private func load() async {
        isLoading = true
        preview = nil
        errorMessage = nil
        defer { isLoading = false }
        do {
            let result = try await store.iCloudMigrationPreview(sourceAccountID: sourceAccountID)
            guard !Task.isCancelled else { return }
            preview = result
        } catch is CancellationError { }
        catch {
            if !Task.isCancelled { errorMessage = store.iCloudErrorMessage(error) }
        }
    }
}
