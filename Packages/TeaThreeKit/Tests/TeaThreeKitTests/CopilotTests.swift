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
        settings.copilotModel = ModelSelection(instanceId: "claudeAgent", model: "claude-opus-5-5")
        settings.workerModel = ModelSelection(instanceId: "codex", model: "gpt-6.2-sol")
        settings.extraInstructions = "Food goes in the Health project."
        let copilot = Copilot(client: .fake(server), settings: settings, store: store)

        let id = try await copilot.ensureThread()
        let launch = try #require(server.calls(to: "t3_thread_launch").first?.arguments)
        #expect(launch["title"] == "Tea Three Copilot")
        // No project chosen: the broadest project on the server, never a separate scratch folder.
        #expect(launch["projectId"] == "f5d40789-8ddf-4d0b-8748-70c4a1d8a009")
        #expect(launch["scratch"] == nil)
        let message = try #require(launch["message"]?.stringValue)
        #expect(message.contains("t3_thread_launch"))
        #expect(message.contains("gpt-6.2-sol"))
        #expect(message.contains("Food goes in the Health project."))
        #expect(launch["modelSelection"]?["instanceId"] == "claudeAgent")
        #expect(launch["modelSelection"]?["model"] == "claude-opus-5-5")

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
        var settings = CopilotSettings.default
        settings.copilotModel = ModelSelection(instanceId: "claudeAgent", model: "claude-sonnet-5-5")
        let id = try await Copilot(client: .fake(server), settings: settings, store: store).ensureThread()
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

@Suite("Model and project choice")
struct ModelChoiceTests {
    @Test("with no model picked, nothing is launched and the user is told to pick one")
    func needsModel() async throws {
        let server = FakeT3()
        server.toolHandler = { name, _ in name == "t3_thread_search" ? ["matches": []] : nil }
        let copilot = Copilot(client: .fake(server), settings: .default, store: .ephemeral())
        await #expect(throws: T3Error.needsModel) { try await copilot.ensureThread() }
        #expect(server.calls(to: "t3_thread_launch").isEmpty)
    }

    @Test("picking a model switches the existing Copilot thread")
    func switchesModel() async throws {
        let server = FakeT3()
        server.toolHandler = { name, _ in name == "t3_thread_configure" ? ["threadId": "copilot-1"] : nil }
        let store = SharedStore.ephemeral()
        store.copilotThreadID = "copilot-1"
        let copilot = Copilot(client: .fake(server), settings: .default, store: store)
        try await copilot.use(ModelSelection(instanceId: "codex", model: "gpt-6.2-sol"))
        let configure = try #require(server.calls(to: "t3_thread_configure").first?.arguments)
        #expect(configure["threadId"] == "copilot-1")
        #expect(configure["modelSelection"]?["model"] == "gpt-6.2-sol")
        #expect(configure["modelSelection"]?["instanceId"] == "codex")
    }

    @Test("the home folder project wins over deeper ones")
    func homeProject() throws {
        let list = try JSONValue.object(["projects": [
            ["id": "deep", "title": "planista", "workspaceRoot": "/home/crabcake/Projects/planista"],
            ["id": "home", "title": "crabcake", "workspaceRoot": "/home/crabcake"],
            ["id": "all", "title": "Projects", "workspaceRoot": "/home/crabcake/Projects"],
        ]]).decode(ProjectListResult.self)
        #expect(Copilot.homeProject(in: list.projects)?.projectId == "home")
    }

    @Test("a Copilot thread in another project isn't reused")
    func ignoresOtherProject() async throws {
        let server = FakeT3()
        server.toolHandler = { name, _ in
            name == "t3_thread_search"
                ? ["matches": [["threadId": "old", "projectId": "elsewhere", "title": "Tea Three Copilot"]]]
                : nil
        }
        var settings = CopilotSettings.default
        settings.projectId = "here"
        settings.copilotModel = ModelSelection(instanceId: "claudeAgent", model: "claude-sonnet-5-5")
        let copilot = Copilot(client: .fake(server), settings: settings, store: .ephemeral())
        #expect(try await copilot.ensureThread() != "old")
        #expect(server.calls(to: "t3_thread_launch").first?.arguments["projectId"] == "here")
    }
}

@Suite("Photos")
struct PhotoTests {
    func server() -> FakeT3 {
        let server = FakeT3()
        server.toolHandler = { name, args in
            switch name {
            case "t3_attachment_prepare_upload":
                let name = args["upload"]?["name"]?.stringValue ?? "x"
                return ["attachmentId": .string("pending-\(name)"), "relativeUrl": .string("/api/attachments/upload/signed-\(name)"), "expiresAt": 1]
            case "t3_thread_send_attachments":
                return ["threadId": args["threadId"] ?? "", "messageId": "m1", "runId": "r1", "status": "running"]
            default:
                return nil
            }
        }
        return server
    }

    @Test("photos are uploaded to the signed URL, then sent with the message")
    func sendsPhotos() async throws {
        let server = server()
        let store = SharedStore.ephemeral()
        store.copilotThreadID = "copilot-1"
        let copilot = Copilot(client: .fake(server), settings: .default, store: store)
        let photo = OutgoingAttachment(data: Data([0xFF, 0xD8, 0xFF, 0x01]), name: "fridge.jpg", mimeType: "image/jpeg")

        let sent = try await copilot.send("what can I cook with this", source: .typed, attachments: [photo])
        #expect(sent.runId == "r1")

        let prepare = try #require(server.calls(to: "t3_attachment_prepare_upload").first?.arguments)
        #expect(prepare["upload"]?["type"] == "image")
        #expect(prepare["upload"]?["mimeType"] == "image/jpeg")
        #expect(prepare["upload"]?["sizeBytes"] == 4)
        #expect(server.uploads["/api/attachments/upload/signed-fridge.jpg"] == photo.data)

        let send = try #require(server.calls(to: "t3_thread_send_attachments").first?.arguments)
        #expect(send["threadId"] == "copilot-1")
        #expect(send["attachments"]?[0]?["id"] == "pending-fridge.jpg")
        #expect(send["attachments"]?[0]?["sizeBytes"] == 4)
        #expect(send["message"]?.stringValue?.contains("1 photo attached") == true)
        #expect(send["message"]?.stringValue?.contains("what can I cook with this") == true)
        #expect(server.calls(to: "t3_thread_send").isEmpty)
    }

    @Test("without photos, the normal send is used")
    func noPhotos() async throws {
        let server = server()
        let store = SharedStore.ephemeral()
        store.copilotThreadID = "copilot-1"
        _ = try await Copilot(client: .fake(server), settings: .default, store: store).send("hi", source: .typed)
        #expect(server.calls(to: "t3_attachment_prepare_upload").isEmpty)
        #expect(server.calls(to: "t3_thread_send_attachments").isEmpty)
        #expect(server.calls(to: "t3_thread_send").count == 1)
    }
}
