import Foundation

/// The single pinned "Copilot" thread every voice request goes to.
public actor Copilot {
    public enum Event: Sendable, Equatable {
        case sent(threadId: String, runId: String?)
        /// Still running after another wait window. `elapsed` in seconds.
        case working(elapsed: TimeInterval)
        /// The run is blocked on an approval or question only the T3 UI can answer.
        case needsAttention
        case finished(reply: String?)
    }

    let client: T3Client
    let settings: CopilotSettings
    let store: SharedStore

    public init(client: T3Client, settings: CopilotSettings, store: SharedStore) {
        self.client = client
        self.settings = settings
        self.store = store
    }

    // MARK: - Thread

    /// Returns the Copilot thread id, creating and pinning the thread on first use.
    public func ensureThread() async throws -> String {
        if let cached = store.copilotThreadID, await isUsable(cached) {
            return cached
        }
        if let found = try await findByTitle() {
            store.copilotThreadID = found
            return found
        }
        // The user picks the model in the app; Tea Three never chooses one.
        guard let model = settings.copilotModel else { throw T3Error.needsModel }
        let launched = try await client.launchThread(.init(
            title: settings.threadTitle,
            message: CopilotPrompts.briefing(settings: settings),
            projectId: try await projectId(),
            modelSelection: model,
            runtimeMode: settings.runtimeMode,
            clientRequestId: "tea-three-copilot-\(UUID().uuidString)"
        ))
        store.copilotThreadID = launched.threadId
        // Pinning only affects the sidebar; never fail setup over it.
        try? await client.organize(threadId: launched.threadId, .pin)
        return launched.threadId
    }

    /// Switches the Copilot thread to `model` now. Threads it starts inherit it.
    /// Before the thread exists there's nothing to change: it's created with the model.
    public func use(_ model: ModelSelection) async throws {
        guard let threadId = store.copilotThreadID else { return }
        try await client.configure(threadId: threadId, modelSelection: model)
    }

    /// The chosen project, or the broadest one on the server (the home folder
    /// project, if there is one) so the Copilot sits with your normal threads
    /// rather than in a scratch folder. `nil` only when the server has no projects.
    func projectId() async throws -> String? {
        if let chosen = settings.projectId { return chosen }
        return Self.homeProject(in: try await client.projects())?.projectId
    }

    public static func homeProject(in projects: [ProjectListResult.Project]) -> ProjectListResult.Project? {
        projects
            .filter { $0.workspaceRoot != nil }
            .min { ($0.workspaceRoot!.split(separator: "/").count, $0.workspaceRoot!) < ($1.workspaceRoot!.split(separator: "/").count, $1.workspaceRoot!) }
    }

    private func isUsable(_ threadId: String) async -> Bool {
        guard let read = try? await client.read(threadId: threadId, limit: 1, maxCharsPerItem: 1) else { return false }
        return read.thread.archived != true
    }

    private func findByTitle() async throws -> String? {
        let matches = try await client.searchThreads(settings.threadTitle, limit: 10)
        // A Copilot left behind in another project isn't this one.
        let projectId = try await projectId()
        for match in matches where match.title == settings.threadTitle && (projectId == nil || match.projectId == nil || match.projectId == projectId) {
            if await isUsable(match.threadId) { return match.threadId }
        }
        return nil
    }

    /// Forgets the cached thread so the next request finds or recreates it.
    public func reset() {
        store.copilotThreadID = nil
    }

    // MARK: - Sending

    /// Fire-and-forget: returns once T3 has accepted the message.
    @discardableResult
    public func send(_ text: String, source: CopilotPrompts.Source, requestID: String = UUID().uuidString) async throws -> ThreadSendResult {
        let threadId = try await ensureThread()
        let message = CopilotPrompts.envelope(text, source: source)
        // Independent drops from Siri queue behind whatever is running; a live
        // conversation steers it, like interrupting a person mid-sentence.
        let mode: SendMode = source == .siri ? .queue : .auto
        do {
            return try await client.send(threadId: threadId, message: message, mode: mode, clientRequestId: requestID)
        } catch T3Error.tool(_, let code, _) where code == "not_found" {
            // Someone deleted the Copilot thread. Rebuild it and retry once.
            reset()
            let rebuilt = try await ensureThread()
            return try await client.send(threadId: rebuilt, message: message, mode: mode, clientRequestId: requestID)
        }
    }

    /// Sends and waits for the Copilot's reply, reporting progress along the way.
    public func ask(
        _ text: String,
        source: CopilotPrompts.Source = .voice,
        waitWindow: TimeInterval = 20,
        onEvent: @Sendable (Event) async -> Void = { _ in }
    ) async throws -> String? {
        let sent = try await send(text, source: source)
        await onEvent(.sent(threadId: sent.threadId, runId: sent.runId))
        let start = Date()

        while true {
            try Task.checkCancellation()
            let waited = try await client.wait(threadId: sent.threadId, runId: sent.runId, timeout: waitWindow)
            if waited.timedOut != true { break }
            if waited.status == "waiting" {
                await onEvent(.needsAttention)
                return nil
            }
            await onEvent(.working(elapsed: Date().timeIntervalSince(start)))
        }

        let reply = try await latestReply(threadId: sent.threadId, runId: sent.runId)
        await onEvent(.finished(reply: reply))
        return reply
    }

    /// The last assistant message of a run (or of the thread when `runId` is nil).
    public func latestReply(threadId: String, runId: String?) async throws -> String? {
        // The `messages` view pages forward from the start and the Copilot thread
        // only grows, so resume from where the last read ended.
        var after = store.readCursor(threadId: threadId)
        var latest: String?
        repeat {
            let page = try await client.read(threadId: threadId, limit: 50, maxCharsPerItem: 4000, afterPosition: after)
            latest = page.finalAssistantText(runId: runId) ?? latest
            guard let next = page.nextPosition, next != after else { break }
            after = next
            if page.hasMore != true { break }
        } while true
        if let after { store.setReadCursor(after, threadId: threadId) }
        return latest
    }

    // MARK: - Outbox

    /// Retries requests that failed to send (phone offline when Siri fired).
    @discardableResult
    public func flushOutbox() async -> Int {
        var sent = 0
        for item in store.outbox {
            do {
                try await send(item.text, source: item.source, requestID: item.id)
                store.removeFromOutbox(id: item.id)
                sent += 1
            } catch let error as T3Error {
                if case .unauthorized = error { break }
                if case .transport = error { break }
                // The server rejected this one outright; don't retry it forever.
                store.removeFromOutbox(id: item.id)
            } catch {
                break
            }
        }
        return sent
    }
}
