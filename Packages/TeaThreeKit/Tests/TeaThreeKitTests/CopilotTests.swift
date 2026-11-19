import Foundation
import Testing
@testable import TeaThreeKit

@Suite("Copilot")
struct CopilotTests {
    let readFixture: JSONValue
    let copilotThreadId: String

    init() throws {
        readFixture = try Fixture.json("t3_thread_read-copilot")
        copilotThreadId = readFixture["thread"]?["threadId"]?.stringValue ?? ""
    }

    @Test("first use: finds the pinned thread by its exact title")
    func findsExistingThread() async throws {
        let server = FakeT3()
        let id = copilotThreadId
        server.toolHandler = { name, _ in
            guard name == "t3_thread_search" else { return nil }
            return ["matches": [
                ["threadId": "other", "title": "Tea Three Copilot (old notes)"],
                ["threadId": .string(id), "title": "Tea Three Copilot"],
            ]]
        }
        let store = SharedStore.ephemeral()
        let copilot = Copilot(client: .fake(server), settings: .default, store: store)
        #expect(try await copilot.ensureThread() == id)
        #expect(store.copilotThreadID == id)
        #expect(server.calls(to: "t3_thread_launch").isEmpty)
    }

    @Test("first use with no thread: launches with the briefing, then pins it")
    func launchesAndPins() async throws {
        let server = FakeT3()
        server.toolHandler = { name, _ in name == "t3_thread_search" ? ["matches": []] : nil }
        let store = SharedStore.ephemeral()
        var settings = CopilotSettings.default
        settings.workerModel = ModelSelection(instanceId: "codex", model: "gpt-6.2-sol")
        settings.extraInstructions = "Food goes in the Health project."
        let copilot = Copilot(client: .fake(server), settings: settings, store: store)

        let id = try await copilot.ensureThread()
        let launch = try #require(server.calls(to: "t3_thread_launch").first?.arguments)
        #expect(launch["title"] == "Tea Three Copilot")
        #expect(launch["scratch"] == true)
        let message = try #require(launch["message"]?.stringValue)
        #expect(message.contains("t3_thread_launch"))
        #expect(message.contains("gpt-6.2-sol"))
        #expect(message.contains("Food goes in the Health project."))
        // No model chosen: picked from orchestrator_capabilities.
        #expect(launch["modelSelection"]?["instanceId"] == "claudeAgent")
        #expect(launch["modelSelection"]?["model"]?.stringValue?.hasPrefix("claude-sonnet") == true)

        let pin = try #require(server.calls(to: "t3_thread_organize").first?.arguments)
        #expect(pin["action"] == "pin")
        #expect(pin["threadId"] == .string(id))
    }

    @Test("an archived cached thread is replaced")
    func archivedThreadIsReplaced() async throws {
        let server = FakeT3()
        let fixture = readFixture
        server.toolHandler = { name, args in
            switch name {
            case "t3_thread_read" where args["threadId"] == "stale":
                guard case .object(var root) = fixture, case .object(var thread)? = root["thread"] else { return nil }
                thread["archived"] = true
                root["thread"] = .object(thread)
                return .object(root)
            case "t3_thread_search": return ["matches": []]
            default: return nil
            }
        }
        let store = SharedStore.ephemeral()
        store.copilotThreadID = "stale"
        let id = try await Copilot(client: .fake(server), settings: .default, store: store).ensureThread()
        #expect(id != "stale")
        #expect(server.calls(to: "t3_thread_launch").count == 1)
    }

    @Test("Siri drops queue; live voice uses auto (steers a running turn)")
    func sendModes() async throws {
        let server = FakeT3()
        let store = SharedStore.ephemeral()
        store.copilotThreadID = copilotThreadId
        let copilot = Copilot(client: .fake(server), settings: .default, store: store)

        try await copilot.send("log a burrito", source: .siri)
        try await copilot.send("what's running?", source: .voice)
        let sends = server.calls(to: "t3_thread_send").map(\.arguments)
        #expect(sends.map { $0["mode"] } == ["queue", "auto"])
        #expect(sends[0]["message"]?.stringValue?.contains("fire-and-forget") == true)
        #expect(sends[0]["message"]?.stringValue?.hasSuffix("\nlog a burrito") == true)
        #expect(sends[1]["message"]?.stringValue?.contains("read aloud") == true)
    }

    @Test("ask keeps waiting through timeouts, then reads that run's reply")
    func askWaitsForReply() async throws {
        let server = FakeT3()
        let fixture = readFixture
        let lastRun = fixture["items"]?.arrayValue?.last?["runId"] ?? .null
        let waits = Counter()
        server.toolHandler = { name, _ in
            switch name {
            case "t3_thread_send": return ["threadId": "c", "runId": lastRun, "status": "starting", "delivery": "started"]
            case "t3_thread_wait":
                let attempt = waits.increment()
                return ["threadId": "c", "runId": lastRun, "status": attempt < 3 ? "running" : "completed", "timedOut": .bool(attempt < 3)]
            default: return nil
            }
        }
        let store = SharedStore.ephemeral()
        store.copilotThreadID = copilotThreadId
        let events = EventLog()
        let reply = try await Copilot(client: .fake(server), settings: .default, store: store)
            .ask("log a burrito") { await events.append($0) }

        #expect(reply?.hasPrefix("Logged") == true)
        #expect(waits.value == 3)
        let recorded = await events.events
        #expect(recorded.filter { if case .working = $0 { true } else { false } }.count == 2)
        #expect(recorded.last == .finished(reply: reply))
    }

    @Test("a run blocked on approval is reported, not waited on forever")
    func needsAttention() async throws {
        let server = FakeT3()
        server.toolHandler = { name, _ in
            name == "t3_thread_wait" ? ["threadId": "c", "runId": "r", "status": "waiting", "timedOut": true] : nil
        }
        let store = SharedStore.ephemeral()
        store.copilotThreadID = copilotThreadId
        let events = EventLog()
        let reply = try await Copilot(client: .fake(server), settings: .default, store: store)
            .ask("delete the repo") { await events.append($0) }
        #expect(reply == nil)
        #expect(await events.events.contains(.needsAttention))
    }

    @Test("read cursor: later asks don't re-read the whole thread")
    func readCursor() async throws {
        let server = FakeT3()
        let store = SharedStore.ephemeral()
        store.copilotThreadID = copilotThreadId
        let copilot = Copilot(client: .fake(server), settings: .default, store: store)
        _ = try await copilot.latestReply(threadId: copilotThreadId, runId: nil)
        _ = try await copilot.latestReply(threadId: copilotThreadId, runId: nil)
        let reads = server.calls(to: "t3_thread_read").map(\.arguments).filter { $0["limit"] == 50 }
        #expect(reads.first?["afterPosition"] == nil)
        #expect(reads.last?["afterPosition"] == 14)
    }
}

@Suite("Siri drop + outbox")
struct DropTests {
    @Test("delivered drop says Sent")
    func delivered() async throws {
        let server = FakeT3()
        let store = SharedStore.ephemeral()
        store.copilotThreadID = try Fixture.json("t3_thread_read-copilot")["thread"]?["threadId"]?.stringValue
        let service = TeaThreeService(credentials: MemoryCredentialStore.paired, store: store, transport: server)
        let result = await service.drop("  log a burrito ")
        #expect(result.delivered)
        #expect(result.dialog == "Sent.")
        #expect(server.calls(to: "t3_thread_send").first?.arguments["message"]?.stringValue?.hasSuffix("\nlog a burrito") == true)
    }

    @Test("offline drop is saved and sent next time")
    func offlineThenFlush() async throws {
        let offline = FakeT3()
        offline.httpHandler = { _, _ in (503, [:], Data("gateway down".utf8)) }
        let store = SharedStore.ephemeral()
        store.copilotThreadID = try Fixture.json("t3_thread_read-copilot")["thread"]?["threadId"]?.stringValue

        let first = await TeaThreeService(credentials: MemoryCredentialStore.paired, store: store, transport: offline).drop("log a burrito")
        #expect(!first.delivered)
        #expect(first.dialog.contains("saved it"))
        #expect(store.outbox.map(\.text) == ["log a burrito"])
        let queuedID = try #require(store.outbox.first?.id)

        let online = FakeT3()
        let second = await TeaThreeService(credentials: MemoryCredentialStore.paired, store: store, transport: online).drop("and a coffee")
        #expect(second.delivered)
        #expect(store.outbox.isEmpty)
        let sent = online.calls(to: "t3_thread_send").compactMap { $0.arguments["message"]?.stringValue }
        #expect(sent.count == 2)
        #expect(sent[0].hasSuffix("log a burrito"))
        #expect(sent[1].hasSuffix("and a coffee"))
        // Retries reuse the outbox id, so T3 dedupes a send that actually landed.
        #expect(online.calls(to: "t3_thread_send").first?.arguments["clientRequestId"] == .string(queuedID))
    }

    @Test("unpaired drop tells you to open the app and saves nothing")
    func unpaired() async {
        let store = SharedStore.ephemeral()
        let result = await TeaThreeService(credentials: MemoryCredentialStore(), store: store, transport: FakeT3()).drop("hi")
        #expect(!result.delivered)
        #expect(result.dialog.contains("Open the app"))
        #expect(store.outbox.isEmpty)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() -> Int { lock.withLock { count += 1; return count } }
}

actor EventLog {
    var events: [Copilot.Event] = []
    func append(_ event: Copilot.Event) { events.append(event) }
}
