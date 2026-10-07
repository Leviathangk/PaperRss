import SwiftUI
import WebKit
#if SWIFT_PACKAGE
import PaperRssCore
#endif

struct ICloudArchiveReaderView: View {
    @ObservedObject var store: AppStore
    let accountID: String
    @Environment(\.dismiss) private var dismiss
    @State private var catalog: ICloudArchiveCatalog?
    @State private var items: [ICloudArchiveListItem] = []
    @State private var selectedID: String?
    @State private var section: ICloudArchiveQuery.Section = .articles
    @State private var collection: Collection = .all
    @State private var starredOnly = false
    @State private var search = ""
    @State private var page = 0
    @State private var hasMore = false
    @State private var isLoading = false
    @State private var catalogError: String?
    @State private var listError: String?
    private enum Collection: Hashable { case all, feed(String), folder(String) }
    private struct LoadID: Equatable { let account: String; let query: ICloudArchiveQuery }
    private var query: ICloudArchiveQuery {
        let feed: String? = if section == .articles, case .feed(let id) = collection { id } else { nil }
        let folder: String? = if section == .articles, case .folder(let id) = collection { id } else { nil }
        return .init(section: section, feedID: feed, folderID: folder,
            starredOnly: section == .articles && starredOnly, search: search, page: page)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(I18N.localized("只读本机归档", englishFallback: "Read-only Local Archive"), systemImage: "archivebox")
                    .font(.title2.bold())
                Spacer()
                Button(I18N.localized("完成", englishFallback: "Done")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(I18N.localized("阅读保留原状态，只加载已保存的正文和 AI 产物。外部图片与脚本不会加载；需要访问网站时可主动打开原文。", englishFallback: "Reading preserves the original states and only loads saved content and AI results. External images and scripts do not load. You can explicitly open the original page to visit its website."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HSplitView {
                VStack(alignment: .leading, spacing: 10) {
                    Picker(I18N.localized("归档内容", englishFallback: "Archive Content"), selection: $section) {
                        Text(I18N.localized("文章", englishFallback: "Articles")).tag(ICloudArchiveQuery.Section.articles)
                        Text(I18N.localized("AI 产物", englishFallback: "AI Results")).tag(ICloudArchiveQuery.Section.ai)
                    }.pickerStyle(.segmented)
                    if section == .articles {
                        Picker(I18N.localized("订阅与目录", englishFallback: "Feeds and Folders"), selection: $collection) {
                            Text(I18N.localized("全部文章", englishFallback: "All Articles")).tag(Collection.all)
                            if let catalog {
                                ForEach(catalog.folders) { Text($0.name).tag(Collection.folder($0.id)) }
                                Divider()
                                ForEach(catalog.feeds) { Text($0.name).tag(Collection.feed($0.id)) }
                            }
                        }
                        Toggle(I18N.localized("仅收藏", englishFallback: "Starred Only"), isOn: $starredOnly)
                    }
                    TextField(I18N.localized("搜索归档", englishFallback: "Search Archive"), text: $search)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("icloud.archiveSearch")
                    if let error = listError ?? catalogError { Text(error).font(.caption).foregroundStyle(.orange) }
                    List(items, selection: $selectedID) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .top, spacing: 6) {
                                if section == .articles, item.isStarred { Image(systemName: "star.fill").foregroundStyle(.orange) }
                                if section == .articles, !item.isRead { Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.secondary).padding(.top, 6) }
                                Text(item.title.isEmpty ? archiveAIName(item.source) : item.title).lineLimit(3)
                            }
                            HStack {
                                Text(section == .ai ? archiveAIName(item.source) : item.source).lineLimit(1)
                                Spacer()
                                if let date = item.date { Text(date, format: .dateTime.year().month().day()) }
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .tag(item.id)
                    }
                    .overlay {
                        if isLoading { ProgressView() }
                        else if items.isEmpty, listError == nil {
                            Text(I18N.localized("此范围没有归档资料", englishFallback: "No Archived Data in This Range")).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("icloud.archiveItems")
                    .disabled(isLoading)
                    HStack {
                        Button(I18N.localized("上一页", englishFallback: "Previous page")) { page -= 1 }.disabled(page == 0 || isLoading)
                        Spacer()
                        Text(I18N.shared.localizedFormat("第 %lld 页", page + 1)).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(I18N.localized("下一页", englishFallback: "Next page")) { page += 1 }.disabled(!hasMore || isLoading)
                    }
                }
                .padding(.trailing, 12)
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
                Group {
                    if let selectedID {
                        ICloudArchiveDetailView(store: store, accountID: accountID, id: selectedID, section: section)
                            .id("\(section.rawValue)|\(selectedID)")
                    } else {
                        Text(I18N.localized("选择一份归档资料阅读", englishFallback: "Select Archived Data to Read"))
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .frame(minWidth: 860, minHeight: 580, idealHeight: 680)
        .task(id: accountID) {
            do {
                let loaded = try await store.iCloudArchiveCatalog(accountID: accountID)
                if !Task.isCancelled { catalog = loaded; catalogError = nil }
            } catch is CancellationError {}
            catch { if !Task.isCancelled { catalogError = store.iCloudErrorMessage(error) } }
        }
        .task(id: LoadID(account: accountID, query: query)) { await load(query) }
        .onChange(of: section) { _, _ in page = 0 }
        .onChange(of: collection) { _, _ in page = 0 }
        .onChange(of: starredOnly) { _, _ in page = 0 }
        .onChange(of: search) { _, _ in page = 0 }
        .onChange(of: query) { _, _ in selectedID = nil }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("icloud.archiveReaderSheet")
    }

    private func load(_ request: ICloudArchiveQuery) async {
        isLoading = true; listError = nil
        defer { if query == request { isLoading = false } }
        do {
            if !request.search.isEmpty { try await Task.sleep(for: .milliseconds(200)) }
            let loaded = try await store.iCloudArchivePage(accountID: accountID, query: request)
            guard !Task.isCancelled, query == request else { return }
            items = loaded.items; hasMore = loaded.hasMore
        } catch is CancellationError {}
        catch {
            if !Task.isCancelled, query == request { items = []; hasMore = false; listError = store.iCloudErrorMessage(error) }
        }
    }
}

private struct ICloudArchiveDetailView: View {
    @ObservedObject var store: AppStore
    let accountID, id: String
    let section: ICloudArchiveQuery.Section
    @State private var detail: ICloudArchiveDetail?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let detail {
                HStack(alignment: .top) {
                    Text(detail.title.isEmpty ? I18N.localized("本机 AI 产物", englishFallback: "Local AI Results") : detail.title).font(.title3.bold()).textSelection(.enabled)
                    Spacer()
                    if let url = detail.originalURL {
                        Link(I18N.localized("打开原文", englishFallback: "Open Original"), destination: url)
                    }
                }
                if let author = detail.author { Text(author).font(.caption).foregroundStyle(.secondary) }
                if section == .articles {
                    TabView {
                        Group {
                            if let document = detail.document { ICloudArchiveWebView(document: document) }
                            else { Text(I18N.localized("此文章没有已保存的正文", englishFallback: "No Saved Content for This Article")).foregroundStyle(.secondary) }
                        }
                            .tabItem { Text(I18N.localized("正文", englishFallback: "Content")) }
                        aiContent(detail.localAI)
                            .tabItem { Text(I18N.localized("本机 AI 产物", englishFallback: "Local AI Results")) }
                    }
                } else { aiContent(detail.localAI) }
            } else if let errorMessage {
                Text(errorMessage).foregroundStyle(.orange)
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .padding(.leading, 12)
        .task {
            do {
                let loaded = try await store.iCloudArchiveDetail(accountID: accountID, id: id, section: section)
                if !Task.isCancelled { detail = loaded }
            } catch is CancellationError {}
            catch { if !Task.isCancelled { errorMessage = store.iCloudErrorMessage(error) } }
        }
    }

    private func aiContent(_ values: [ICloudArchiveAIResult]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if values.isEmpty {
                    Text(I18N.localized("没有已保存的 AI 产物", englishFallback: "No Saved AI Results")).foregroundStyle(.secondary)
                }
                ForEach(values, id: \.id) { value in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(archiveAIName(value.kind)).font(.headline)
                            Text(value.targetLanguage).foregroundStyle(.secondary)
                            Spacer()
                            Text(Date(timeIntervalSince1970: value.updatedAt), format: .dateTime.year().month().day()).font(.caption)
                        }
                        if !value.isComplete {
                            Text(I18N.localized("保存时尚未完成，保留当时的内容。", englishFallback: "Incomplete when saved; the content is retained as it was.")).font(.caption).foregroundStyle(.secondary)
                        }
                        if let selection = value.selectionText, !selection.isEmpty {
                            Text(selection).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Text(value.content).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Divider()
                }
                if section == .articles, values.count == 100 {
                    Text(I18N.localized("更多历史结果可在归档的“AI 产物”列表中查看。", englishFallback: "More historical results can be viewed in the archive’s AI Results list.")).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(12)
        }
    }
}

private func archiveAIName(_ kind: String) -> String {
    switch kind {
    case "summary": I18N.localized("摘要结果", englishFallback: "Summary Result")
    case "translation": I18N.localized("翻译结果", englishFallback: "Translation Result")
    case "bilingual": I18N.localized("双语翻译结果", englishFallback: "Bilingual Translation Result")
    default: I18N.localized("本机 AI 产物", englishFallback: "Local AI Results")
    }
}

/// A separate WebKit surface has no reader bridge, automation or persistence.
/// Only a deliberate HTTP(S) link click can leave the offline document.
struct ICloudArchiveWebView: NSViewRepresentable {
    let document: ReaderDocument
    static func makeReadOnlyWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        return WKWebView(frame: .zero, configuration: configuration)
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let view = Self.makeReadOnlyWebView()
        view.navigationDelegate = context.coordinator
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.signature != document.renderSignature else { return }
        context.coordinator.signature = document.renderSignature
        view.loadHTMLString(document.html, baseURL: nil)
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading(); view.navigationDelegate = nil
    }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var signature: String?
        var onFinish: (() -> Void)?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onFinish?() }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            let url = action.request.url
            if action.navigationType == .linkActivated, let url,
               let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
               components.host?.isEmpty == false, components.user == nil, components.password == nil {
                NSWorkspace.shared.open(url)
            }
            let address = url?.absoluteString ?? ""
            let isLocalDocument = url == nil || address == "about:blank" || address.hasPrefix("about:blank#")
            decisionHandler(isLocalDocument ? .allow : .cancel)
        }
    }
}
