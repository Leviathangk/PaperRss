import Foundation
import XCTest
@testable import PaperRssCore

private actor TemperatureCapturePort: AIModelPort {
    private var replies: [AIModelHTTPResponse]
    private var requests: [URLRequest] = []
    init(_ replies: [AIModelHTTPResponse]) { self.replies = replies }

    func data(for request: URLRequest) async throws -> AIModelHTTPResponse {
        requests.append(request)
        guard !replies.isEmpty else { throw LLMServiceError.invalidResponse }
        return replies.removeFirst()
    }

    func events(for request: URLRequest) async throws -> AIModelEventResponse {
        requests.append(request)
        return AIModelEventResponse(statusCode: 200, lines: AsyncThrowingStream { continuation in
            continuation.yield("data: [DONE]")
            continuation.finish()
        })
    }
    func captured() -> [URLRequest] { requests }
}

final class LLMTemperatureTests: XCTestCase {
    private let endpoints = ["https://api.moonshot.cn/v1", "https://api.moonshot.ai/v1", "https://models.example.test/v1"]

    private func configuration(_ endpoint: String, model: String = "kimi-k3") -> LLMConfiguration {
        LLMConfiguration(baseURL: endpoint, model: model, temperature: 0.2, targetLanguage: "简体中文",
                         allowInsecureLocalEndpoint: false, providerKind: .customOpenAICompatible)
    }
    private func request(_ value: LLMConfiguration, stream: Bool = false, override: Double? = nil) throws -> URLRequest {
        try LLMService(port: TemperatureCapturePort([])).makeRequest(
            prompt: "Fixture", system: "Fixture", configuration: value, apiKey: "", stream: stream,
            overrideTemperature: override)
    }
    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }
    private func reply() -> AIModelHTTPResponse {
        AIModelHTTPResponse(statusCode: 200, data: Data(#"{"choices":[{"message":{"content":"OK"}}]}"#.utf8))
    }

    func testOfficialEndpointVariantsOmitTemperatureAcrossChatShapesAndStreaming() throws {
        let official = Array(endpoints.prefix(2)) + ["HTTPS://API.MOONSHOT.CN:443/v1/",
            " https://api.moonshot.ai/v1/\n", "https://api.moonshot.cn/%76%31"]
        let models = ["kimi-k3", " kimi-k2.6\n", "moonshotai/kimi-k2.5",
            "KIMI-K2-THINKING-TURBO", "kimi-k2.7-code-highspeed"]
        for endpoint in official {
            for model in models {
                for adaptation in [AIModelAdaptation.automatic, .chat, .userMessage] {
                    var value = configuration(endpoint, model: model)
                    value.adaptation = adaptation
                    for stream in [false, true] {
                        let sent = try request(value, stream: stream, override: 0.9)
                        let payload = try body(sent)
                        let label = "\(endpoint) \(model) \(adaptation) \(stream)"
                        XCTAssertNil(payload["temperature"], label)
                        XCTAssertNil(payload["reasoning_effort"], label)
                        XCTAssertNil(payload["thinking"], label)
                        XCTAssertNil(sent.value(forHTTPHeaderField: "Authorization"), label)
                        XCTAssertEqual(payload["stream"] as? Bool, stream, label)
                        XCTAssertEqual(sent.url?.path, "/v1/chat/completions", label)
                        let messages = try XCTUnwrap(payload["messages"] as? [[String: String]])
                        XCTAssertEqual(messages.map { $0["role"] ?? "" },
                            adaptation == .userMessage ? ["user"] : ["system", "user"], label)
                    }
                }
            }
        }
    }

    func testOtherModelsKeepTemperatureAndOverrideWhileGemini3StillOmits() throws {
        let gemini = "https://generativelanguage.googleapis.com/v1beta/openai"
        let cases = [("https://api.openai.com/v1", "gpt-4o-mini"),
            ("https://api.deepseek.com/v1", "deepseek-v4-flash"), (gemini, "gemini-2.5-flash"),
            (endpoints[0], "moonshot-v1-8k"), (endpoints[1], "kimi-k2-0905-preview"),
            (endpoints[0], "kimi-k30"), (endpoints[1], "kimi-k2.50")]
        for (endpoint, model) in cases {
            let value = configuration(endpoint, model: model)
            XCTAssertEqual(try body(request(value))["temperature"] as? Double, 0.2, model)
            XCTAssertEqual(try body(request(value, override: 0.9))["temperature"] as? Double, 0.9, model)
        }
        let value = configuration(gemini, model: "gemini-3-flash")
        XCTAssertNil(try body(request(value, override: 0.9))["temperature"])
    }

    func testConnectionAndUserMessageProbeRespectEndpointTemperatureContract() async throws {
        let failure = AIModelHTTPResponse(statusCode: 400,
            data: Data(#"{"error":{"message":"system role is not supported"}}"#.utf8))
        for endpoint in endpoints {
            let expected: Double? = endpoint == endpoints.last ? 0.2 : nil
            let value = configuration(endpoint)
            let direct = TemperatureCapturePort([reply()])
            try await LLMService(port: direct).test(configuration: value, apiKey: "")
            let directRequests = await direct.captured()
            XCTAssertEqual(directRequests.count, 1)
            XCTAssertEqual(try body(try XCTUnwrap(directRequests.first))["temperature"] as? Double, expected, endpoint)
            let probe = TemperatureCapturePort([failure, reply()])
            let result = try await LLMService(port: probe).probeConnection(configuration: value, apiKey: "")
            XCTAssertEqual(result.suggestedAdaptation, .userMessage)
            let requests = await probe.captured()
            XCTAssertEqual(requests.count, 2)
            for sent in requests {
                XCTAssertEqual(try body(sent)["temperature"] as? Double, expected, endpoint)
                XCTAssertNil(sent.value(forHTTPHeaderField: "Authorization"))
            }
            let messages = try XCTUnwrap(try body(try XCTUnwrap(requests.last))["messages"] as? [[String: String]])
            XCTAssertEqual(messages.map { $0["role"] ?? "" }, ["user"])
        }
    }

    func testEmptyStreamFallbackRespectsEndpointAndTemperatureOverride() async throws {
        for endpoint in endpoints {
            let port = TemperatureCapturePort([reply()])
            let output = try await LLMService(port: port).complete(
                prompt: "Fixture", system: "Fixture", configuration: configuration(endpoint), apiKey: "",
                onDelta: { _ in }, overrideTemperature: 0.9)
            XCTAssertEqual(output, "OK")
            let requests = await port.captured()
            XCTAssertEqual(requests.count, 2)
            let expected: Double? = endpoint == endpoints.last ? 0.9 : nil
            for sent in requests {
                XCTAssertEqual(try body(sent)["temperature"] as? Double, expected, endpoint)
                XCTAssertNil(sent.value(forHTTPHeaderField: "Authorization"))
            }
            XCTAssertEqual(try body(try XCTUnwrap(requests.first))["stream"] as? Bool, true)
            XCTAssertEqual(try body(try XCTUnwrap(requests.last))["stream"] as? Bool, false)
        }
    }

    func testDisplayAliasDoesNotReplaceWireModelIdentity() throws {
        func runtime(_ id: String, displayName: String) -> LLMConfiguration {
            AIProviderProfile(id: "fixture", kind: .customOpenAICompatible, name: "Fixture", description: "",
                baseURL: endpoints[0], selectedModelID: id,
                models: [AIModelOption(id: id, displayName: displayName)]).runtimeConfiguration(features: .default)
        }
        let known = try body(request(runtime("kimi-k3", displayName: "my-kimi")))
        XCTAssertEqual(known["model"] as? String, "kimi-k3")
        XCTAssertNil(known["temperature"])
        let alias = try body(request(runtime("my-kimi", displayName: "kimi-k3")))
        XCTAssertEqual(alias["model"] as? String, "my-kimi")
        XCTAssertEqual(alias["temperature"] as? Double, 0.2)
    }
}
