import Foundation

/// The single pinned "Clanker" thread every voice request goes to.
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
        if let cached = store.copilotThreadID, let title = await usableTitle(cached) {
            await renameIfNeeded(cached, from: title)
            return cached
        }
        if let (found, title) = try await findByTitle() {
            store.copilotThreadID = found
            await renameIfNeeded(found, from: title)
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

    /// The thread's title, or nil if it's gone or archived.
    private func usableTitle(_ threadId: String) async -> String? {
        guard let read = try? await client.read(threadId: threadId, limit: 1, maxCharsPerItem: 1),
              read.thread.archived != true else { return nil }
        return read.thread.title
    }

    /// Keeps the thread's name in T3 Code in step with the setting (an old
    /// "Tea Three Clanker" becomes "Tea Three Clanker"). Cosmetic: never fails a request.
    private func renameIfNeeded(_ threadId: String, from title: String) async {
        guard title != settings.threadTitle else { return }
        try? await client.rename(threadId: threadId, to: settings.threadTitle)
    }

    private func findByTitle() async throws -> (String, String)? {
        // A Copilot left behind in another project isn't this one.
        let projectId = try await projectId()
        for title in [settings.threadTitle] + CopilotSettings.legacyThreadTitles {
            let matches = try await client.searchThreads(title, limit: 10)
            for match in matches where match.title == title && (projectId == nil || match.projectId == nil || match.projectId == projectId) {
                if let current = await usableTitle(match.threadId) { return (match.threadId, current) }
            }
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
    public func send(
        _ text: String,
        source: CopilotPrompts.Source,
        attachments: [OutgoingAttachment] = [],
        requestID: String = UUID().uuidString
    ) async throws -> ThreadSendResult {
        let threadId = try await ensureThread()
        let message = CopilotPrompts.envelope(text, source: source, attachmentCount: attachments.count)
        // Uploads aren't tied to a thread, so a rebuilt thread can reuse them.
        var uploads: [UploadedAttachment] = []
        for attachment in attachments {
            uploads.append(try await client.upload(attachment))
        }
        let uploaded = uploads
        // Independent drops from Siri queue behind whatever is running; a live
        // conversation steers it, like interrupting a person mid-sentence.
        let mode: SendMode = source == .siri ? .queue : .auto
        func deliver(to threadId: String) async throws -> ThreadSendResult {
            uploaded.isEmpty
                ? try await client.send(threadId: threadId, message: message, mode: mode, clientRequestId: requestID)
                : try await client.sendAttachments(threadId: threadId, message: message, attachments: uploaded)
        }
        do {
            return try await deliver(to: threadId)
        } catch T3Error.tool(_, let code, _) where code == "not_found" {
            // Someone deleted the Copilot thread. Rebuild it and retry once.
            reset()
            return try await deliver(to: try await ensureThread())
        }
    }

    /// Sends and waits for the Copilot's reply, reporting progress along the way.
    public func ask(
        _ text: String,
        source: CopilotPrompts.Source = .voice,
        attachments: [OutgoingAttachment] = [],
        requestID: String = UUID().uuidString,
        waitWindow: TimeInterval = 20,
        onEvent: @Sendable (Event) async -> Void = { _ in }
    ) async throws -> String? {
        let sent = try await send(text, source: source, attachments: attachments, requestID: requestID)
        await onEvent(.sent(threadId: sent.threadId, runId: sent.runId))
        return try await awaitReply(threadId: sent.threadId, runId: sent.runId, waitWindow: waitWindow, onEvent: onEvent)
    }

    /// Waits for a run to finish and returns its reply. Also used for a turn
    /// that a steer started because the previous one had just ended.
    public func awaitReply(
        threadId: String,
        runId: String?,
        readingAfter readStart: Int? = nil,
        waitWindow: TimeInterval = 20,
        onEvent: @Sendable (Event) async -> Void = { _ in }
    ) async throws -> String? {
        let start = Date()
        while true {
            try Task.checkCancellation()
            let waited = try await client.wait(threadId: threadId, runId: runId, timeout: waitWindow)
            if waited.timedOut != true { break }
            if waited.status == "waiting" {
                await onEvent(.needsAttention)
                return nil
            }
            await onEvent(.working(elapsed: Date().timeIntervalSince(start)))
        }

        let reply = try await latestReply(threadId: threadId, runId: runId, after: readStart)
        await onEvent(.finished(reply: reply))
        return reply
    }

    /// Adds to the request the Copilot is working on: a running turn takes it as
    /// a mid-turn update (`delivery` "steered"), like interrupting a person
    /// mid-sentence. If the turn has just ended it starts a new one instead; the
    /// caller follows that run with `awaitReply`.
    @discardableResult
    public func steer(
        _ text: String,
        source: CopilotPrompts.Source,
        attachments: [OutgoingAttachment] = [],
        requestID: String = UUID().uuidString
    ) async throws -> ThreadSendResult {
        try await send(text, source: source, attachments: attachments, requestID: requestID)
    }

    /// Stops the Copilot's running turn ("cancel that"). False when there's no
    /// Copilot thread yet, so nothing could be stopped.
    @discardableResult
    public func interrupt() async throws -> Bool {
        guard let threadId = store.copilotThreadID else { return false }
        try await client.interrupt(threadId: threadId)
        return true
    }

    /// The last assistant message of a run (or of the thread when `runId` is nil).
    /// `start` reads from an earlier position than the shared cursor: for a run
    /// whose reply another lookup may already have read past.
    public func latestReply(threadId: String, runId: String?, after start: Int? = nil) async throws -> String? {
        // The `messages` view pages forward from the start and the Copilot thread
        // only grows, so resume from where the last read ended.
        var after = start ?? store.readCursor(threadId: threadId)
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
    /// Returns what happened to each item it settled, by id: true if sent,
    /// false if the server rejected it. Items still waiting aren't listed.
    @discardableResult
    public func flushOutbox() async -> [String: Bool] {
        var settled: [String: Bool] = [:]
        for item in store.outbox {
            do {
                try await send(item.text, source: item.source, requestID: item.id)
                store.removeFromOutbox(id: item.id)
                settled[item.id] = true
            } catch let error as T3Error {
                if case .unauthorized = error { break }
                if case .transport = error { break }
                // The server rejected this one outright; don't retry it forever.
                store.removeFromOutbox(id: item.id)
                settled[item.id] = false
            } catch {
                break
            }
        }
        return settled
    }
}
