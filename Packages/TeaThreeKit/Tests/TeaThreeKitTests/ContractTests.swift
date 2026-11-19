import Foundation
import Testing
@testable import TeaThreeKit

/// Recorded-fixture contract tests: the tool schemas and result shapes of the
/// last T3 Code version Tea Three was verified against. To add a version, run
/// `tea-three record Tests/TeaThreeKitTests/Fixtures/vX.Y.Z` against it and
/// add it to `versions`.
@Suite("Contract: recorded fixtures")
struct ContractTests {
    static let versions = ["v0.1.9"]

    @Test("tool schemas satisfy the contract", arguments: versions)
    func schemasSatisfyContract(version: String) throws {
        let violations = ToolContract.check(try Fixture.tools(version: version))
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("every result fixture decodes", arguments: versions)
    func resultsDecode(version: String) throws {
        _ = try Fixture.json("orchestrator_capabilities", version: version).decode(OrchestratorCapabilities.self)
        _ = try Fixture.json("t3_project_list", version: version).decode(ProjectListResult.self)
        _ = try Fixture.json("t3_thread_launch", version: version).decode(ThreadLaunchResult.self)
        _ = try Fixture.json("t3_thread_search", version: version).decode(ThreadSearchResult.self)
        _ = try Fixture.json("t3_thread_list", version: version).decode(ThreadListResult.self)
        _ = try Fixture.json("t3_thread_wait-idle", version: version).decode(ThreadWaitResult.self)
        _ = try Fixture.json("t3_thread_read-copilot", version: version).decode(ThreadReadResult.self)
    }

    @Test("project list accepts `id` and `projectId`")
    func projectIdentifierAliases() throws {
        let old = try JSONValue.object(["projects": [["projectId": "p1", "title": "One"]], "nextCursor": nil])
            .decode(ProjectListResult.self)
        let new = try Fixture.json("t3_project_list").decode(ProjectListResult.self)
        #expect(old.projects.first?.projectId == "p1")
        #expect(new.projects.allSatisfy { !$0.projectId.isEmpty })
    }

    @Test("reply comes from the matching run")
    func finalAssistantTextPerRun() throws {
        let read = try Fixture.json("t3_thread_read-copilot").decode(ThreadReadResult.self)
        let runs = read.items.compactMap(\.runId)
        let lastRun = try #require(runs.last)
        let firstRun = try #require(runs.first)
        #expect(read.finalAssistantText(runId: lastRun)?.hasPrefix("Logged") == true)
        #expect(read.finalAssistantText(runId: firstRun) == "1")
        #expect(read.finalAssistantText(runId: "run-that-does-not-exist") == nil)
    }

    @Test("`final_answer` phase wins over later commentary")
    func prefersFinalAnswerPhase() throws {
        let read = try JSONValue.object([
            "thread": ["threadId": "t", "title": "Copilot"],
            "items": [
                ["position": 1, "runId": "r", "type": "assistant_message", "text": "The answer.", "phase": "final_answer"],
                ["position": 2, "runId": "r", "type": "assistant_message", "text": "(also checked logs)", "phase": "commentary"],
            ],
        ]).decode(ThreadReadResult.self)
        #expect(read.finalAssistantText(runId: "r") == "The answer.")
    }

    // MARK: The checker itself catches drift

    func mutate(_ transform: (inout [String: JSONValue]) -> Void) throws -> [MCPClient.Tool] {
        var tools = try JSONValue.from(Fixture.tools()).arrayValue ?? []
        tools = tools.map { tool in
            guard var object = tool.objectValue else { return tool }
            transform(&object)
            return .object(object)
        }
        return try JSONValue.array(tools).decode([MCPClient.Tool].self)
    }

    @Test("flags a removed tool as breaking")
    func removedTool() throws {
        let tools = try Fixture.tools().filter { $0.name != "t3_thread_send" }
        let violations = ToolContract.check(tools)
        #expect(violations.contains { $0.tool == "t3_thread_send" && $0.critical && $0.problem == "tool is gone" })
    }

    @Test("flags a renamed argument")
    func renamedArgument() throws {
        let tools = try mutate { tool in
            guard tool["name"] == "t3_thread_send", case .object(var schema)? = tool["inputSchema"],
                  case .object(var properties)? = schema["properties"] else { return }
            properties["text"] = properties.removeValue(forKey: "message")
            schema["properties"] = .object(properties)
            schema["required"] = ["threadId", "text"]
            tool["inputSchema"] = .object(schema)
        }
        let problems = ToolContract.check(tools).filter { $0.tool == "t3_thread_send" }.map(\.problem)
        #expect(problems.contains("argument `message` is gone"))
        #expect(problems.contains("new required argument `text`"))
    }

    @Test("flags a dropped enum value")
    func droppedEnumValue() throws {
        let tools = try mutate { tool in
            guard tool["name"] == "t3_thread_send", case .object(var schema)? = tool["inputSchema"],
                  case .object(var properties)? = schema["properties"], case .object(var mode)? = properties["mode"] else { return }
            mode["enum"] = ["auto", "steer"]
            properties["mode"] = .object(mode)
            schema["properties"] = .object(properties)
            tool["inputSchema"] = .object(schema)
        }
        let violations = ToolContract.check(tools)
        #expect(violations.contains { $0.problem.contains("no longer accepts \"queue\"") })
    }

    @Test("non-critical losses are reported as degraded, not breaking")
    func degradedTool() throws {
        let tools = try Fixture.tools().filter { $0.name != "t3_thread_organize" }
        let violations = ToolContract.check(tools)
        #expect(violations.count == 1)
        #expect(violations.first?.critical == false)
    }

    @Test("model options (reasoning effort, fast mode) decode from capabilities")
    func modelOptions() throws {
        let caps = try JSONValue.object(["providers": [[
            "providerInstanceId": "claudeAgent", "displayName": "Claude",
            "models": [["id": "claude-opus-5-5", "label": "Claude Opus 5.5", "options": [
                ["id": "effort", "values": ["low", "medium", "high", "ultrathink"], "default": "medium"],
                ["id": "fastMode", "values": [false, true]],
            ]]],
        ]]]).decode(OrchestratorCapabilities.self)
        let found = try #require(caps.lookup(ModelSelection(instanceId: "claudeAgent", model: "claude-opus-5-5")))
        let options = try #require(found.model.options)
        #expect(options[0].id == "effort" && options[0].default == "medium" && !options[0].isToggle)
        #expect(options[1].isToggle && options[1].default == nil)
        #expect(caps.lookup(ModelSelection(instanceId: "codex", model: "claude-opus-5-5")) == nil)
    }
}
