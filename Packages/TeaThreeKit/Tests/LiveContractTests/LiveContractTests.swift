import Foundation
import Testing
import TeaThreeKit

/// Contract tests against a real T3 Code server. No model is ever run, so they
/// work on a fresh `t3 serve` in CI with no provider logins.
///
///     T3_CONTRACT_PAIRING_URL='http://127.0.0.1:3773/pair#token=XXXX' swift test --filter LiveContractTests
///
/// CI starts `t3@latest` and `t3@nightly` from npm and runs these nightly, so a
/// breaking upstream change shows up as a red build before it shows up on the phone.
@Suite("Contract: live server", .serialized, .enabled(if: LiveServer.pairingURL != nil))
struct LiveContractTests {
    @Test("pairs, satisfies the tool contract, and round-trips a thread")
    func liveRoundTrip() async throws {
        let link = try PairingLink.parse(try #require(LiveServer.pairingURL))
        let credential = try await MCPOAuth().pair(link, clientName: "Tea Three contract test")
        #expect(credential.scope?.contains("orchestration:operate") == true)

        let client = T3Client(credential: credential)
        let tools = try await client.mcp.listTools()
        let violations = ToolContract.check(tools)
        let breaking = violations.filter(\.critical)
        #expect(breaking.isEmpty, "Breaking changes: \(breaking)")
        if !violations.isEmpty { print("Contract warnings: \(violations)") }

        let capabilities = try await client.capabilities()
        let model = try #require(capabilities.firstModel, "server lists no models")

        let title = "tea-three contract \(UUID().uuidString.prefix(8))"
        let launched = try await client.launchThread(.init(title: title, modelSelection: model))
        #expect(!launched.threadId.isEmpty)

        let matches = try await client.searchThreads(title)
        #expect(matches.contains { $0.threadId == launched.threadId && $0.title == title })

        let listed = try await client.listThreads(limit: 50, titleContains: title)
        #expect(listed.contains { $0.threadId == launched.threadId })

        try await client.organize(threadId: launched.threadId, .pin)

        let read = try await client.read(threadId: launched.threadId, limit: 5)
        #expect(read.thread.threadId == launched.threadId)
        #expect(read.thread.title == title)

        let waited = try await client.wait(threadId: launched.threadId, timeout: 2)
        #expect(waited.timedOut == false, "an idle thread should not block wait")

        try await client.organize(threadId: launched.threadId, .archive)
        let archived = try await client.read(threadId: launched.threadId, limit: 1)
        #expect(archived.thread.archived == true)
    }
}

enum LiveServer {
    static var pairingURL: String? {
        ProcessInfo.processInfo.environment["T3_CONTRACT_PAIRING_URL"].flatMap { $0.isEmpty ? nil : $0 }
    }
}
