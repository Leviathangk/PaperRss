import Foundation
import Darwin
import PaperRssAgentProtocol
import PaperRssAgentMCP

@main
enum PaperRssAgentMain {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--version"] {
            print("paperrss-agent 0.1.0-spike")
            return
        }
        guard args.starts(with: ["serve", "--stdio"]), validOptions(Array(args.dropFirst(2))) else {
            diagnostic("Usage: paperrss-agent serve --stdio [--client LABEL] [--fixture]\n")
            exit(2)
        }
        let enabled = ProcessInfo.processInfo.environment["PAPERRSS_AGENT_ENABLED"] == "1"
        let bridge: any AgentBridge = args.contains("--fixture")
            ? AgentFixtureBridge(enabled: enabled) : AgentUnavailableBridge(enabled: enabled)
        // --client is a diagnostic label only, never an authentication identity.
        let server = AgentMCPServer(bridge: bridge)
        let sink = OutputSink()
        do {
            try await Task.detached { try await serve(server: server, sink: sink) }.value
        } catch {
            diagnostic("stdio transport failed\n")
            exit(1)
        }
    }

    private static func validOptions(_ args: [String]) -> Bool {
        var index = 0, fixture = false, client = false
        while index < args.count {
            switch args[index] {
            case "--fixture" where !fixture:
                fixture = true
                index += 1
            case "--client" where !client:
                guard index + 1 < args.count, !args[index + 1].hasPrefix("--"),
                      !args[index + 1].isEmpty, args[index + 1].utf8.count <= 128 else { return false }
                client = true
                index += 2
            default: return false
            }
        }
        return true
    }

    /// Cap bytes before JSON parsing, and cap outstanding tasks. Newlines inside
    /// JSON strings must be escaped, as required by the MCP stdio transport.
    private static func serve(server: AgentMCPServer, sink: OutputSink) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            var line = Data(), droppingOversize = false, outstanding = 0
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while true {
                // A single POSIX read returns available pipe bytes; Foundation's
                // read(upToCount:) can wait for more bytes and stall initialize.
                let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                for byte in buffer.prefix(count) {
                    if byte == 10 {
                        if droppingOversize {
                            let oversized = Data(repeating: 32, count: AgentMCPServer.maximumRequestBytes + 1)
                            if let result = await server.handle(data: oversized) { try await sink.write(result) }
                        } else if !line.isEmpty {
                            let request = line
                            group.addTask {
                                if let response = await server.handle(data: request) { try await sink.write(response) }
                            }
                            outstanding += 1
                            if outstanding >= 32 { try await group.next(); outstanding -= 1 }
                        }
                        line.removeAll(keepingCapacity: true)
                        droppingOversize = false
                    } else if !droppingOversize {
                        if line.count >= AgentMCPServer.maximumRequestBytes {
                            droppingOversize = true
                            line.removeAll(keepingCapacity: true)
                        } else { line.append(byte) }
                    }
                }
            }
            // EOF with an unfinished frame cannot be interpreted as a complete request.
            if !line.isEmpty || droppingOversize {
                diagnostic("Ignored unterminated stdio frame\n")
            }
            group.cancelAll()
            await server.cancelAll()
            try await group.waitForAll()
        }
    }

    private static func diagnostic(_ text: String) {
        do { try FileHandle.standardError.write(contentsOf: Data(text.utf8)) }
        catch { /* No safe diagnostic channel remains. */ }
    }
}

private actor OutputSink {
    func write(_ data: Data) throws {
        var frame = data
        frame.append(10)
        try FileHandle.standardOutput.write(contentsOf: frame)
    }
}
