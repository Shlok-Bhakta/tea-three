import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Minimal MCP "Streamable HTTP" client: JSON-RPC over POST, with the
/// `Mcp-Session-Id` handshake. T3 Code answers with plain JSON, but SSE
/// framed answers are accepted too in case that ever changes.
public actor MCPClient {
    public static let protocolVersion = "2025-06-18"

    public struct Tool: Sendable, Codable, Hashable {
        public let name: String
        public let description: String?
        public let inputSchema: JSONValue?
    }

    public struct ServerInfo: Sendable, Codable, Hashable {
        public let name: String
        public let version: String
    }

    let endpoint: URL
    let tokenProvider: @Sendable () async throws -> String
    let transport: HTTPTransport
    let clientName: String
    let clientVersion: String

    private var sessionID: String?
    private var nextID = 1
    public private(set) var serverInfo: ServerInfo?

    public init(
        endpoint: URL,
        transport: HTTPTransport = URLSessionTransport(),
        clientName: String = "tea-three",
        clientVersion: String = TeaThree.version,
        tokenProvider: @escaping @Sendable () async throws -> String
    ) {
        self.endpoint = endpoint
        self.transport = transport
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.tokenProvider = tokenProvider
    }

    // MARK: - Public API

    public func listTools() async throws -> [Tool] {
        var tools: [Tool] = []
        var cursor: String?
        repeat {
            var params: [String: JSONValue] = [:]
            if let cursor { params["cursor"] = .string(cursor) }
            let result = try await request("tools/list", params: .object(params))
            tools += try (result["tools"] ?? .array([])).decode([Tool].self)
            cursor = result["nextCursor"]?.stringValue
        } while cursor != nil
        return tools
    }

    /// Calls a tool and returns its structured result. Throws `T3Error.tool` when
    /// the tool reports `isError`.
    public func callTool(_ name: String, arguments: JSONValue, timeout: TimeInterval = 60) async throws -> JSONValue {
        let result = try await request(
            "tools/call",
            params: ["name": .string(name), "arguments": arguments],
            timeout: timeout
        )
        return try Self.unwrapToolResult(name: name, result: result)
    }

    public func callTool<Arguments: Encodable, Output: Decodable>(
        _ name: String,
        _ arguments: Arguments,
        as output: Output.Type,
        timeout: TimeInterval = 60
    ) async throws -> Output {
        let value = try await callTool(name, arguments: JSONValue.from(arguments), timeout: timeout)
        do {
            return try value.decode(Output.self)
        } catch {
            throw T3Error.protocolMismatch("\(name) result didn't decode as \(Output.self): \(error)")
        }
    }

    // MARK: - Tool results

    static func unwrapToolResult(name: String, result: JSONValue) throws -> JSONValue {
        let textPayload: JSONValue? = result["content"]?.arrayValue?
            .first(where: { $0["type"]?.stringValue == "text" })?["text"]?.stringValue
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }

        if result["isError"]?.boolValue == true {
            let rawText = result["content"]?.arrayValue?.first?["text"]?.stringValue ?? "unknown error"
            throw T3Error.tool(
                name: name,
                code: textPayload?["code"]?.stringValue,
                message: textPayload?["message"]?.stringValue ?? rawText
            )
        }
        if let structured = result["structuredContent"], structured != .null {
            return structured
        }
        if let textPayload {
            return textPayload
        }
        throw T3Error.protocolMismatch("\(name) returned no structured content")
    }

    // MARK: - JSON-RPC plumbing

    private func ensureSession() async throws {
        guard sessionID == nil else { return }
        let result = try await rawRequest(
            "initialize",
            params: [
                "protocolVersion": .string(Self.protocolVersion),
                "capabilities": [:],
                "clientInfo": ["name": .string(clientName), "version": .string(clientVersion)],
            ],
            timeout: 20
        )
        serverInfo = try? (result["serverInfo"] ?? .null).decode(ServerInfo.self)
        try await notify("notifications/initialized")
    }

    func request(_ method: String, params: JSONValue, timeout: TimeInterval = 60) async throws -> JSONValue {
        try await ensureSession()
        do {
            return try await rawRequest(method, params: params, timeout: timeout)
        } catch SessionExpired.expired {
            // The server forgot our session (restart, idle reap). Start over once.
            sessionID = nil
            try await ensureSession()
            return try await rawRequest(method, params: params, timeout: timeout)
        }
    }

    private enum SessionExpired: Error { case expired }

    private func notify(_ method: String) async throws {
        let body: JSONValue = ["jsonrpc": "2.0", "method": .string(method)]
        _ = try await post(body, timeout: 20)
    }

    private func rawRequest(_ method: String, params: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        let id = nextID
        nextID += 1
        let body: JSONValue = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params]
        let (data, response) = try await post(body, timeout: timeout)

        if response.statusCode == 404, sessionID != nil, method != "initialize" {
            throw SessionExpired.expired
        }
        guard (200..<300).contains(response.statusCode) else {
            throw T3Error.transport("HTTP \(response.statusCode) for \(method): \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        if method == "initialize", let session = response.value(forHTTPHeaderField: "Mcp-Session-Id") {
            sessionID = session
        }

        let message = try Self.decodeResponse(data: data, contentType: response.value(forHTTPHeaderField: "Content-Type"), id: id)
        if let error = message["error"] {
            let code = error["code"].flatMap { if case .number(let n) = $0 { Int(n) } else { nil } } ?? 0
            throw T3Error.rpc(code: code, message: error["message"]?.stringValue ?? "unknown")
        }
        guard let result = message["result"] else {
            throw T3Error.protocolMismatch("\(method) response had neither result nor error")
        }
        return result
    }

    private func post(_ body: JSONValue, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(Self.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        request.setValue("Bearer \(try await tokenProvider())", forHTTPHeaderField: "Authorization")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }

        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await transport.send(request)
        } catch let error as T3Error {
            throw error
        } catch {
            throw T3Error.transport(error.localizedDescription)
        }
        if response.statusCode == 401 || response.statusCode == 403 {
            throw T3Error.unauthorized(Self.authReason(data) ?? "HTTP \(response.statusCode)")
        }
        return (data, response)
    }

    static func authReason(_ data: Data) -> String? {
        guard let body = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return body["reason"]?.stringValue ?? body["error_description"]?.stringValue ?? body["error"]?.stringValue
    }

    /// Accepts both `application/json` and `text/event-stream` bodies.
    static func decodeResponse(data: Data, contentType: String?, id: Int) throws -> JSONValue {
        if contentType?.contains("text/event-stream") == true {
            let text = String(decoding: data, as: UTF8.self)
            for event in text.components(separatedBy: "\n\n") {
                let payload = event
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .filter { $0.hasPrefix("data:") }
                    .map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }
                    .joined(separator: "\n")
                guard let json = try? JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8)) else { continue }
                if case .number(let n) = json["id"] ?? .null, Int(n) == id { return json }
            }
            throw T3Error.protocolMismatch("No JSON-RPC response for id \(id) in event stream")
        }
        do {
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw T3Error.protocolMismatch("Response wasn't JSON: \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
    }
}
