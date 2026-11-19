import Foundation
import Testing
@testable import TeaThreeKit

@Suite("MCP client")
struct MCPClientTests {
    @Test("initializes once, then reuses the session")
    func handshake() async throws {
        let server = FakeT3()
        let client = T3Client.fake(server)
        _ = try await client.projects()
        _ = try await client.searchThreads("Copilot")
        #expect(server.methods == ["initialize", "notifications/initialized", "tools/call", "tools/call"])
        #expect(await client.mcp.serverInfo?.version == "0.1.9")
    }

    @Test("re-initializes when the server forgets the session")
    func sessionExpiry() async throws {
        let server = FakeT3()
        let client = T3Client.fake(server)
        _ = try await client.projects()
        server.dropSessions = true
        _ = try await client.projects()
        #expect(server.methods.filter { $0 == "initialize" }.count == 2)
        #expect(server.calls(to: "t3_project_list").count == 2)
    }

    @Test("401 means re-pair")
    func unauthorized() async throws {
        let server = FakeT3()
        server.httpHandler = { _, _ in
            (401, [:], Data(#"{"_tag":"EnvironmentAuthInvalidError","code":"auth_invalid","reason":"invalid_credential"}"#.utf8))
        }
        await #expect(throws: T3Error.unauthorized("invalid_credential")) {
            _ = try await T3Client.fake(server).projects()
        }
    }

    @Test("tool failures carry T3's error code")
    func toolError() async throws {
        let server = FakeT3()
        server.toolHandler = { name, _ in
            if name == "t3_thread_launch" { throw FakeT3.ToolFailure(code: "invalid_request", message: "Pass modelSelection") }
            return nil
        }
        await #expect(throws: T3Error.tool(name: "t3_thread_launch", code: "invalid_request", message: "Pass modelSelection")) {
            _ = try await T3Client.fake(server).launchThread(.init(title: "x"))
        }
    }

    @Test("reads SSE-framed responses too")
    func eventStream() throws {
        let body = """
        event: message
        data: {"jsonrpc":"2.0","method":"notifications/progress","params":{}}

        event: message
        data: {"jsonrpc":"2.0","id":7,"result":{"ok":true}}


        """
        let message = try MCPClient.decodeResponse(data: Data(body.utf8), contentType: "text/event-stream", id: 7)
        #expect(message["result"]?["ok"] == true)
    }

    @Test("falls back to the text content when there's no structuredContent")
    func textContentFallback() throws {
        let result: JSONValue = ["content": [["type": "text", "text": #"{"sequence":5}"#]], "isError": false]
        #expect(try MCPClient.unwrapToolResult(name: "t3_thread_organize", result: result)["sequence"] == 5)
    }

    @Test("launch outside a project asks for a scratch folder")
    func launchScratch() async throws {
        let server = FakeT3()
        _ = try await T3Client.fake(server).launchThread(.init(title: "x", modelSelection: .init(instanceId: "claudeAgent", model: "m")))
        _ = try await T3Client.fake(server).launchThread(.init(title: "y", projectId: "p1"))
        let launches = server.calls(to: "t3_thread_launch").map(\.arguments)
        #expect(launches[0]["scratch"] == true)
        #expect(launches[0]["projectId"] == nil)
        #expect(launches[1]["scratch"] == nil)
        #expect(launches[1]["projectId"] == "p1")
    }
}
