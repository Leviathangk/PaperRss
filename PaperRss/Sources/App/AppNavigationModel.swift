import SwiftUI
#if SWIFT_PACKAGE
import PaperRssCore
#endif

@MainActor
final class AppNavigationModel: ObservableObject {
    var opensSettingsOnNextWindow = false

    enum Destination: Equatable {
        case unread
        case agent(accountID: String, feedID: UUID, articleID: String?)
    }

    struct Request: Identifiable, Equatable {
        let id = UUID()
        let destination: Destination
    }

    @Published private(set) var request: Request?

    @Published private(set) var agentOpenedArticleID: String?

    func openAgent(request: AgentOpenRequest) {
        agentOpenedArticleID = request.articleID
        self.request = Request(destination: .agent(accountID: request.accountID, feedID: request.feedID, articleID: request.articleID))
    }

    func shouldAutomaticallyMarkRead(_ articleID: String) -> Bool {
        agentOpenedArticleID != articleID
    }

    func didSelectArticle(_ articleID: String?) {
        if articleID != agentOpenedArticleID { agentOpenedArticleID = nil }
    }

    func openUnread() {
        agentOpenedArticleID = nil
        request = Request(destination: .unread)
    }
}
