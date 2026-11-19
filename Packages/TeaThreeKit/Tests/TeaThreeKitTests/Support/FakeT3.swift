import Foundation
@testable import TeaThreeKit

enum Fixture {
    static let version = "v0.1.9"

    static func data(_ name: String, version: String = version) throws -> Data {
        guard let url = Bundle.module.url(forResource: "Fixtures/\(version)/\(name)", withExtension: "json") else {
            throw FixtureMissing(name: name)
        }
        return try Data(contentsOf: url)
    }

    static func json(_ name: String, version: String = version) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data(name, version: version))
    }

    static func tools(version: String = version) throws -> [MCPClient.Tool] {
        try JSONDecoder().decode([MCPClient.Tool].self, from: data("tools-list", version: version))
    }

    struct FixtureMissing: Error { let name: String }
}

/// An in-memory stand-in for a T3 Code server's `/mcp` endpoint. Tool results
/// come from recorded fixtures so the shapes match a real server.
final class FakeT3: HTTPTransport, @unchecked Sendable {
    struct Call: Equatable {
        let tool: String
        let arguments: JSONValue
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _methods: [String] = []
    private var sessionCounter = 0

    /// Overrides by tool name. Return `nil` to fall through to the fixture.
    var toolHandler: (@Sendable (String, JSONValue) throws -> JSONValue?)?
    /// Raw HTTP override, consulted first (for status-code tests).
    var httpHandler: (@Sendable (URLRequest, JSONValue) -> (Int, [String: String], Data)?)?
    /// Pretend the server restarted: the next request with an old session gets 404.
    var dropSessions = false

    var calls: [Call] { lock.withLock { _calls } }
    var methods: [String] { lock.withLock { _methods } }
    func calls(to tool: String) -> [Call] { calls.filter { $0.tool == tool } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data("{}".utf8))
        let method = body["method"]?.stringValue ?? ""
        lock.withLock { _methods.append(method) }

        if let override = httpHandler?(request, body) {
            return (override.2, response(request, status: override.0, headers: override.1))
        }

        if dropSessions, method != "initialize", request.value(forHTTPHeaderField: "Mcp-Session-Id") != nil {
            dropSessions = false
            return (Data(), response(request, status: 404))
        }

        switch method {
        case "initialize":
            let session = lock.withLock { () -> String in
                sessionCounter += 1
                return "session-\(sessionCounter)"
            }
            let result: JSONValue = [
                "protocolVersion": "2025-06-18",
                "capabilities": ["tools": ["listChanged": true]],
                "serverInfo": ["name": "T3 Code", "version": "0.1.9"],
            ]
            return (try rpc(body, result: result), response(request, status: 200, headers: ["Mcp-Session-Id": session]))
        case "notifications/initialized":
            return (Data(), response(request, status: 202))
        case "tools/list":
            let tools = try JSONValue.from(Fixture.tools())
            return (try rpc(body, result: ["tools": tools]), response(request, status: 200))
        case "tools/call":
            let name = body["params"]?["name"]?.stringValue ?? ""
            let arguments = body["params"]?["arguments"] ?? [:]
            lock.withLock { _calls.append(Call(tool: name, arguments: arguments)) }
            do {
                let structured = try toolHandler?(name, arguments) ?? Self.fixtureResult(for: name)
                return (try rpc(body, result: Self.toolResult(structured)), response(request, status: 200))
            } catch let failure as ToolFailure {
                return (try rpc(body, result: failure.result), response(request, status: 200))
            }
        default:
            return (try rpc(body, error: ["code": -32601, "message": "Method not found"]), response(request, status: 200))
        }
    }

    struct ToolFailure: Error {
        let code: String
        let message: String

        var result: JSONValue {
            let text = #"{"_tag":"OrchestratorMcpFailure","code":"\#(code)","message":"\#(message)"}"#
            return ["content": [["type": "text", "text": .string(text)]], "isError": true]
        }
    }

    static func fixtureResult(for tool: String) throws -> JSONValue {
        switch tool {
        case "t3_thread_read": try Fixture.json("t3_thread_read-copilot")
        case "t3_thread_wait": try Fixture.json("t3_thread_wait-idle")
        case "t3_thread_send":
            [
                "threadId": "thread-copilot", "messageId": "message-1", "runId": "run-1",
                "status": "starting", "delivery": "started",
            ]
        default: try Fixture.json(tool)
        }
    }

    static func toolResult(_ structured: JSONValue) throws -> JSONValue {
        let text = String(decoding: try JSONEncoder().encode(structured), as: UTF8.self)
        return ["content": [["type": "text", "text": .string(text)]], "structuredContent": structured, "isError": false]
    }

    private func rpc(_ body: JSONValue, result: JSONValue? = nil, error: JSONValue? = nil) throws -> Data {
        var message: [String: JSONValue] = ["jsonrpc": "2.0", "id": body["id"] ?? .null]
        if let result { message["result"] = result }
        if let error { message["error"] = error }
        return try JSONEncoder().encode(JSONValue.object(message))
    }

    private func response(_ request: URLRequest, status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"].merging(headers) { _, new in new }
        )!
    }
}

extension T3Client {
    static func fake(_ server: FakeT3) -> T3Client {
        T3Client(mcp: MCPClient(endpoint: URL(string: "http://t3.test:3773/mcp")!, transport: server, tokenProvider: { "test-token" }))
    }
}

extension SharedStore {
    static func ephemeral() -> SharedStore {
        let suite = "tea-three-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return SharedStore(defaults: defaults)
    }
}

/// Credential store that lives in memory.
final class MemoryCredentialStore: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var credential: T3Credential?

    init(_ credential: T3Credential? = nil) {
        self.credential = credential
    }

    func load() -> T3Credential? { lock.withLock { credential } }
    func save(_ credential: T3Credential) throws { lock.withLock { self.credential = credential } }
    func clear() { lock.withLock { credential = nil } }

    static let paired = MemoryCredentialStore(T3Credential(
        serverURL: URL(string: "http://t3.test:3773")!,
        accessToken: "test-token",
        expiresAt: Date().addingTimeInterval(86_400),
        scope: "orchestration:read orchestration:operate",
        clientID: "client",
        environmentID: "env",
        environmentLabel: "Test Mac"
    ))
}
