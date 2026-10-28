import Foundation
import XCTest
import PaperRssCore
@testable import PaperRssDesktop

@MainActor
final class AgentNavigationTests: XCTestCase {
    func testArticleOpenCarriesFeedAndSuppressesAutomaticReadUntilSelectionChanges() {
        let navigation = AppNavigationModel()
        let feedID = UUID()
        navigation.openAgent(request: AgentOpenRequest(accountID: "remote", feedID: feedID, articleID: "article"))
        XCTAssertEqual(navigation.request?.destination, .agent(accountID: "remote", feedID: feedID, articleID: "article"))
        XCTAssertFalse(navigation.shouldAutomaticallyMarkRead("article"))
        navigation.didSelectArticle("article")
        XCTAssertFalse(navigation.shouldAutomaticallyMarkRead("article"))
        navigation.didSelectArticle("another")
        XCTAssertTrue(navigation.shouldAutomaticallyMarkRead("article"))
        XCTAssertTrue(navigation.shouldAutomaticallyMarkRead("another"))
    }

    func testDeferredReadGateUsesCurrentNavigationState() {
        let navigation = AppNavigationModel()
        let gate = navigation.shouldAutomaticallyMarkRead
        XCTAssertTrue(gate("article"))
        navigation.openAgent(request: AgentOpenRequest(accountID: "remote", feedID: UUID(), articleID: "article"))
        XCTAssertFalse(gate("article"), "An already captured reader gate must observe a later agent open")
    }

    func testFeedOpenClearsSuppressionAndRepeatedRequestsRemainDeliverable() {
        let navigation = AppNavigationModel()
        let request = AgentOpenRequest(accountID: "local", feedID: UUID(), articleID: "article")
        navigation.openAgent(request: request)
        let firstID = navigation.request?.id
        navigation.openAgent(request: request)
        XCTAssertNotEqual(firstID, navigation.request?.id)
        navigation.openAgent(request: AgentOpenRequest(accountID: "local", feedID: request.feedID))
        XCTAssertEqual(navigation.request?.destination, .agent(accountID: "local", feedID: request.feedID, articleID: nil))
        XCTAssertTrue(navigation.shouldAutomaticallyMarkRead("article"))
        navigation.openUnread()
        XCTAssertEqual(navigation.request?.destination, .unread)
    }
}
