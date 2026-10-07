import Network
import PaperRssCore
import WebKit
import XCTest
@testable import PaperRssDesktop

private final class ArchiveHTTPProbe: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "PaperRssArchiveHTTPProbe")
    private let lock = NSLock()
    private var requests = 0
    private var receivedHTTP = 0
    var count: Int { lock.withLock { requests } }
    var httpCount: Int { lock.withLock { receivedHTTP } }
    var address: String { "http://127.0.0.1:\(listener.port!.rawValue)" }
    init(ready: XCTestExpectation) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.lock.withLock { self.requests += 1 }
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data,_,_,_ in
                if data?.isEmpty == false { self.lock.withLock { self.receivedHTTP += 1 } }
                let body = "<svg xmlns='http://www.w3.org/2000/svg' width='2' height='2'><rect width='2' height='2'/></svg>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: image/svg+xml\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: queue)
    }
    func stop() { listener.cancel() }
}

@MainActor
final class ICloudArchiveWebKitTests: XCTestCase {
    private func load(_ document: ReaderDocument, into view: WKWebView, delegate: ICloudArchiveWebView.Coordinator) async {
        let loaded = expectation(description: "Offline archive document loaded")
        delegate.onFinish = { loaded.fulfill() }
        view.navigationDelegate = delegate
        view.loadHTMLString(document.html, baseURL: nil)
        await fulfillment(of: [loaded], timeout: 10)
        delegate.onFinish = nil
    }
    func testOfflineArchiveRendersSavedTextButBlocksNetworkResourcesAndContentScripts() async throws {
        let ready = expectation(description: "Loopback request probe ready")
        let probe = try ArchiveHTTPProbe(ready: ready)
        defer { probe.stop() }
        await fulfillment(of: [ready], timeout: 5)
        let url = probe.address
        let svg = "<svg xmlns='http://www.w3.org/2000/svg'><image href='\(url)/nested-image'/></svg>"
        let dataImage = "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString()
        let html = """
            <p id='saved'>Saved offline content</p><img src='\(url)/image'>
            <img src='\(dataImage)'>
            <script>window.archiveScriptRan=true;</script><script src='\(url)/script'></script>
            <iframe src='\(url)/frame'></iframe><video src='\(url)/media' preload='auto'></video>
            <style>@import url('\(url)/style'); p {background-image:url('\(url)/background')}</style>
            """
        let article = PreparedArticle(text: "Saved offline content", html: html, imageURLs: [], baseURL: nil, source: .feed)
        let document = ReaderDocumentRenderer.renderDocument(article: article, documentIdentity: "archive", resourcePolicy: .localArchive)
        let view = ICloudArchiveWebView.makeReadOnlyWebView(), delegate = ICloudArchiveWebView.Coordinator()
        XCTAssertTrue(delegate.responds(to: NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")))
        defer { view.stopLoading(); view.navigationDelegate = nil; withExtendedLifetime(delegate) {} }
        XCTAssertFalse(view.configuration.websiteDataStore.isPersistent)
        XCTAssertFalse(view.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertTrue(view.configuration.userContentController.userScripts.isEmpty)
        await load(document, into: view, delegate: delegate)
        let text = try await view.evaluateJavaScript("document.getElementById('saved').textContent")
        XCTAssertEqual(text as? String, "Saved offline content")
        let executed = try await view.evaluateJavaScript("window.archiveScriptRan === true")
        XCTAssertEqual(executed as? Bool, false)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(probe.count, 0)
        XCTAssertNotNil(view.navigationDelegate)
        // Host evaluation is allowed by WebKit even when content scripts are
        // disabled. A content-driven top-level redirect must still be blocked.
        _ = try await view.evaluateJavaScript("window.location.href='\(url)/redirect'")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(probe.count, 0)
        XCTAssertEqual(probe.httpCount, 0)
        let retained = try await view.evaluateJavaScript("document.getElementById('saved').textContent")
        XCTAssertEqual(retained as? String, "Saved offline content")
    }
    func testStandardReaderPositiveControlStillLoadsItsAllowedImage() async throws {
        let ready = expectation(description: "Loopback positive control ready")
        let probe = try ArchiveHTTPProbe(ready: ready)
        defer { probe.stop() }
        await fulfillment(of: [ready], timeout: 5)
        let article = PreparedArticle(text: "Image", html: "<p>Image</p><img src='\(probe.address)/image'>", imageURLs: [], baseURL: nil, source: .feed)
        let document = ReaderDocumentRenderer.renderDocument(article: article, documentIdentity: "standard")
        let view = ICloudArchiveWebView.makeReadOnlyWebView(), delegate = ICloudArchiveWebView.Coordinator()
        defer { view.stopLoading(); view.navigationDelegate = nil; withExtendedLifetime(delegate) {} }
        await load(document, into: view, delegate: delegate)
        XCTAssertGreaterThanOrEqual(probe.count, 1)
        XCTAssertGreaterThanOrEqual(probe.httpCount, 1)
    }
}
