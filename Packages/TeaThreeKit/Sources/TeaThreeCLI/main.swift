import Foundation
import TeaThreeKit

// tea-three: the same client the phone uses, from a terminal. Handy for
// debugging, recording contract fixtures, and the nightly CI contract job.

let usage = """
usage: tea-three <command> [args]

  pair <pairing-url>              Pair using what `t3 pair` prints (or `<server> <code>`)
  status                          Show the paired server
  contract                        Check the server's MCP tools against Tea Three's contract
  lifecycle                       Exercise launch/search/pin/archive without running a model
  record <dir>                    Save live responses as contract fixtures
  model <copilot|worker> <instance/model>   Set a default model (e.g. claudeAgent/claude-haiku-5-5)
  send <text...>                  Fire-and-forget to the Copilot thread (what Siri does)
  ask <text...>                   Send to the Copilot and print its reply (what voice mode does)

env:
  TEA_THREE_CREDENTIAL   credential file (default ~/.config/tea-three/credential.json)
  TEA_THREE_STATE        state suite name for the Copilot thread id (default tea-three-cli)
"""

let arguments = Array(CommandLine.arguments.dropFirst())
let credentialURL = ProcessInfo.processInfo.environment["TEA_THREE_CREDENTIAL"].map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/tea-three/credential.json")
let stateSuite = ProcessInfo.processInfo.environment["TEA_THREE_STATE"] ?? "tea-three-cli"
let service = TeaThreeService(
    credentials: FileCredentialStore(url: credentialURL),
    store: SharedStore(defaults: UserDefaults(suiteName: stateSuite)!)
)

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(code)
}

func run() async throws {
    guard let command = arguments.first else { fail(usage, code: 2) }
    let rest = Array(arguments.dropFirst())

    switch command {
    case "pair":
        let link: PairingLink
        switch rest.count {
        case 1: link = try PairingLink.parse(rest[0])
        case 2: link = try PairingLink(server: rest[0], code: rest[1])
        default: fail("pair <pairing-url> | pair <server> <code>", code: 2)
        }
        let credential = try await service.pair(link)
        print("Paired with \(credential.environmentLabel ?? credential.serverURL.absoluteString)")
        print("Token expires \(credential.expiresAt.map { "\($0)" } ?? "never"); scope: \(credential.scope ?? "?")")

    case "status":
        guard let credential = service.credentials.load() else { fail("not paired") }
        print("server: \(credential.serverURL)")
        print("environment: \(credential.environmentLabel ?? "?") (\(credential.environmentID ?? "?"))")
        print("expires: \(credential.expiresAt.map { "\($0)" } ?? "never")\(credential.isExpired ? " (EXPIRED)" : "")")
        print("copilot thread: \(service.store.copilotThreadID ?? "(none yet)")")

    case "contract":
        let violations = try await service.checkContract()
        print(service.store.lastContractReport ?? "")
        violations.forEach { print("  \($0)") }
        if violations.contains(where: \.critical) { exit(1) }

    case "lifecycle":
        try await lifecycle()

    case "record":
        guard let directory = rest.first else { fail("record <dir>", code: 2) }
        try await record(into: URL(fileURLWithPath: directory))

    case "model":
        guard rest.count == 2, let slash = rest[1].firstIndex(of: "/") else {
            fail("model <copilot|worker> <instance/model>", code: 2)
        }
        let selection = ModelSelection(instanceId: String(rest[1][..<slash]), model: String(rest[1][rest[1].index(after: slash)...]))
        var settings = service.store.settings
        switch rest[0] {
        case "copilot": settings.copilotModel = selection
        case "worker": settings.workerModel = selection
        default: fail("model <copilot|worker> <instance/model>", code: 2)
        }
        service.store.settings = settings
        print("\(rest[0]) model: \(selection.instanceId ?? "")/\(selection.model)")

    case "send":
        let result = await service.drop(rest.joined(separator: " "))
        print(result.dialog)
        if !result.delivered { exit(1) }

    case "ask":
        let copilot = try service.copilot()
        let reply = try await copilot.ask(rest.joined(separator: " "), source: .voice) { event in
            if case .working(let elapsed) = event {
                FileHandle.standardError.write(Data("… still working (\(Int(elapsed))s)\n".utf8))
            }
        }
        print(reply ?? "(no reply)")

    default:
        fail(usage, code: 2)
    }
}

/// Model-free round trip through every tool Tea Three depends on.
/// Leaves nothing behind: the thread it creates is archived at the end.
func lifecycle() async throws {
    let client = try service.client()
    let capabilities = try await client.capabilities()
    guard let provider = capabilities.providers.first(where: { !$0.models.isEmpty }), let model = provider.models.first else {
        fail("server lists no provider with models")
    }
    let title = "tea-three contract \(UUID().uuidString.prefix(8))"
    let launched = try await client.launchThread(.init(
        title: title,
        modelSelection: ModelSelection(instanceId: provider.providerInstanceId, model: model.id)
    ))
    print("launch   ok  \(launched.threadId)")

    let found = try await client.searchThreads(title)
    guard found.contains(where: { $0.threadId == launched.threadId }) else { fail("search didn't find the new thread") }
    print("search   ok")

    let listed = try await client.listThreads(limit: 50, titleContains: title)
    guard listed.contains(where: { $0.threadId == launched.threadId }) else { fail("list didn't include the new thread") }
    print("list     ok")

    try await client.organize(threadId: launched.threadId, .pin)
    print("pin      ok")

    let read = try await client.read(threadId: launched.threadId, limit: 5)
    guard read.thread.threadId == launched.threadId else { fail("read returned another thread") }
    print("read     ok  status=\(read.thread.status ?? "?")")

    let waited = try await client.wait(threadId: launched.threadId, timeout: 2)
    print("wait     ok  status=\(waited.status ?? "?") timedOut=\(waited.timedOut.map(String.init) ?? "?")")

    try await client.organize(threadId: launched.threadId, .archive)
    let archived = try await client.read(threadId: launched.threadId, limit: 1)
    guard archived.thread.archived == true else { fail("archive didn't stick") }
    print("archive  ok")
}

/// Writes raw tool results to `<dir>/<name>.json`, for TeaThreeKitTests/Fixtures.
/// Creates (and archives) one idle thread; reads the Copilot thread if there is one.
func record(into directory: URL) async throws {
    let client = try service.client()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

    func save(_ name: String, _ value: some Encodable) throws {
        try encoder.encode(value).write(to: directory.appendingPathComponent("\(name).json"))
        print("wrote \(name).json")
    }
    func raw(_ tool: String, _ arguments: JSONValue) async throws -> JSONValue {
        try await client.mcp.callTool(tool, arguments: arguments)
    }

    let tools = try await client.mcp.listTools()
    // Only the tools in the contract, so fixture diffs stay readable.
    let needed = Set(ToolContract.requirements.map(\.tool))
    try save("tools-list", tools.filter { needed.contains($0.name) }.sorted { $0.name < $1.name })
    if let info = await client.mcp.serverInfo { try save("server-info", info) }

    let capabilities = try await raw("orchestrator_capabilities", [:])
    try save("orchestrator_capabilities", capabilities)
    try save("t3_project_list", try await raw("t3_project_list", ["limit": 5]))

    let parsed = try capabilities.decode(OrchestratorCapabilities.self)
    guard let model = parsed.firstModel else { fail("no models") }
    let title = "tea-three fixture \(UUID().uuidString.prefix(8))"
    let launched = try await raw("t3_thread_launch", try JSONValue.from(T3Client.LaunchRequest(title: title, modelSelection: model)))
    try save("t3_thread_launch", launched)
    let threadId = launched["threadId"]?.stringValue ?? ""
    try save("t3_thread_search", try await raw("t3_thread_search", ["query": .string(title)]))
    try save("t3_thread_list", try await raw("t3_thread_list", ["allProjects": true, "limit": 3]))
    try save("t3_thread_wait-idle", try await raw("t3_thread_wait", ["threadId": .string(threadId), "timeoutMs": 1000]))
    try save("t3_thread_organize", try await raw("t3_thread_organize", ["threadId": .string(threadId), "action": "archive"]))

    if let copilot = service.store.copilotThreadID {
        try save("t3_thread_read-copilot", try await raw(
            "t3_thread_read", ["threadId": .string(copilot), "view": "messages", "limit": 6, "maxCharsPerItem": 400]
        ))
    }
}

do {
    try await run()
} catch let error as T3Error {
    fail(error.errorDescription ?? "\(error)")
} catch {
    fail("\(error)")
}
