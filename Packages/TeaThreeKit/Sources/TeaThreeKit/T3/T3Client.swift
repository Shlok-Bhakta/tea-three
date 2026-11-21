import Foundation

/// Typed wrappers over the T3 Code MCP tools Tea Three relies on. Every tool
/// name and argument used here is listed in `ToolContract`, so the contract
/// tests catch upstream changes before the phone does.
public struct T3Client: Sendable {
    public let mcp: MCPClient

    public init(mcp: MCPClient) {
        self.mcp = mcp
    }

    public init(credential: T3Credential, transport: HTTPTransport = URLSessionTransport()) {
        let token = credential.accessToken
        self.mcp = MCPClient(endpoint: credential.mcpEndpoint, transport: transport, tokenProvider: { token })
    }

    public func capabilities() async throws -> OrchestratorCapabilities {
        try await mcp.callTool("orchestrator_capabilities", Empty(), as: OrchestratorCapabilities.self)
    }

    public func projects(limit: Int = 100) async throws -> [ProjectListResult.Project] {
        try await mcp.callTool("t3_project_list", ["limit": limit], as: ProjectListResult.self).projects
    }

    public func listThreads(limit: Int = 25, titleContains: String? = nil, snoozed: Bool? = nil) async throws -> [ThreadSummary] {
        struct Args: Encodable {
            let allProjects = true
            let limit: Int
            let titleContains: String?
            let snoozed: Bool?
        }
        return try await mcp.callTool(
            "t3_thread_list",
            Args(limit: limit, titleContains: titleContains, snoozed: snoozed),
            as: ThreadListResult.self
        ).threads
    }

    public func searchThreads(_ query: String, limit: Int = 10) async throws -> [ThreadSearchResult.Match] {
        struct Args: Encodable {
            let query: String
            let limit: Int
        }
        return try await mcp.callTool("t3_thread_search", Args(query: query, limit: limit), as: ThreadSearchResult.self).matches
    }

    public struct LaunchRequest: Encodable, Sendable {
        public var title: String
        public var message: String?
        public var projectId: String?
        public var scratch: Bool?
        public var modelSelection: ModelSelection?
        public var runtimeMode: RuntimeMode?
        public var clientRequestId: String

        public init(
            title: String,
            message: String? = nil,
            projectId: String? = nil,
            modelSelection: ModelSelection? = nil,
            runtimeMode: RuntimeMode? = nil,
            clientRequestId: String = UUID().uuidString
        ) {
            self.title = title
            self.message = message
            self.projectId = projectId
            // Outside a thread, T3 needs either a project or a scratch folder.
            self.scratch = projectId == nil ? true : nil
            self.modelSelection = modelSelection
            self.runtimeMode = runtimeMode
            self.clientRequestId = clientRequestId
        }
    }

    public func launchThread(_ request: LaunchRequest) async throws -> ThreadLaunchResult {
        try await mcp.callTool("t3_thread_launch", request, as: ThreadLaunchResult.self)
    }

    /// Sends a message. Returns as soon as the server accepts it; the agent runs on.
    public func send(
        threadId: String,
        message: String,
        mode: SendMode = .auto,
        clientRequestId: String = UUID().uuidString
    ) async throws -> ThreadSendResult {
        struct Args: Encodable {
            let threadId: String
            let message: String
            let mode: SendMode
            let clientRequestId: String
        }
        return try await mcp.callTool(
            "t3_thread_send",
            Args(threadId: threadId, message: message, mode: mode, clientRequestId: clientRequestId),
            as: ThreadSendResult.self
        )
    }

    /// Uploads one attachment: get a pre-signed URL, then POST the bytes to it.
    public func upload(_ attachment: OutgoingAttachment) async throws -> UploadedAttachment {
        struct Upload: Encodable {
            let type: String
            let name: String
            let mimeType: String
            let sizeBytes: Int
        }
        struct Args: Encodable { let upload: Upload }
        let type = attachment.isImage ? "image" : "file"
        let ticket = try await mcp.callTool(
            "t3_attachment_prepare_upload",
            Args(upload: Upload(type: type, name: attachment.name, mimeType: attachment.mimeType, sizeBytes: attachment.data.count)),
            as: AttachmentUploadTicket.self
        )
        // The ticket path is relative to the server's origin, not to /mcp.
        guard let url = URL(string: ticket.relativeUrl, relativeTo: mcp.endpoint)?.absoluteURL else {
            throw T3Error.protocolMismatch("bad upload URL \(ticket.relativeUrl)")
        }
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue(attachment.mimeType, forHTTPHeaderField: "Content-Type")
        request.httpBody = attachment.data
        let (_, response) = try await mcp.transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw T3Error.transport("photo upload failed (HTTP \(response.statusCode))")
        }
        return UploadedAttachment(type: type, id: ticket.attachmentId, name: attachment.name, mimeType: attachment.mimeType, sizeBytes: attachment.data.count)
    }

    /// Sends a message with uploaded attachments. Like `send` with mode `auto`,
    /// but T3 has no retry key for this tool.
    public func sendAttachments(threadId: String, message: String, attachments: [UploadedAttachment]) async throws -> ThreadSendResult {
        struct Args: Encodable {
            let threadId: String
            let message: String
            let attachments: [UploadedAttachment]
        }
        return try await mcp.callTool(
            "t3_thread_send_attachments",
            Args(threadId: threadId, message: message, attachments: attachments),
            as: ThreadSendResult.self
        )
    }

    /// Long-polls until the run finishes or `timeout` passes (then `timedOut == true`).
    public func wait(threadId: String, runId: String? = nil, timeout: TimeInterval = 25) async throws -> ThreadWaitResult {
        struct Args: Encodable {
            let threadId: String
            let runId: String?
            let timeoutMs: Int
        }
        return try await mcp.callTool(
            "t3_thread_wait",
            Args(threadId: threadId, runId: runId, timeoutMs: Int(timeout * 1000)),
            as: ThreadWaitResult.self,
            timeout: timeout + 15
        )
    }

    public func read(threadId: String, limit: Int = 20, maxCharsPerItem: Int = 4000, afterPosition: Int? = nil) async throws -> ThreadReadResult {
        struct Args: Encodable {
            let threadId: String
            let view = "messages"
            let limit: Int
            let maxCharsPerItem: Int
            let afterPosition: Int?
        }
        return try await mcp.callTool(
            "t3_thread_read",
            Args(threadId: threadId, limit: limit, maxCharsPerItem: maxCharsPerItem, afterPosition: afterPosition),
            as: ThreadReadResult.self
        )
    }

    public func rename(threadId: String, to title: String) async throws {
        struct Args: Encodable {
            let threadId: String
            let action = "rename"
            let title: String
        }
        _ = try await mcp.callTool("t3_thread_update", arguments: JSONValue.from(Args(threadId: threadId, title: title)))
    }

    public func organize(threadId: String, _ action: OrganizeAction, snoozedUntil: Date? = nil) async throws {
        struct Args: Encodable {
            let threadId: String
            let action: OrganizeAction
            let snoozedUntil: String?
        }
        _ = try await mcp.callTool(
            "t3_thread_organize",
            arguments: JSONValue.from(Args(
                threadId: threadId,
                action: action,
                snoozedUntil: snoozedUntil.map { ISO8601DateFormatter().string(from: $0) }
            ))
        )
    }

    public func configure(threadId: String, modelSelection: ModelSelection) async throws {
        struct Args: Encodable {
            let threadId: String
            let modelSelection: ModelSelection
        }
        _ = try await mcp.callTool("t3_thread_configure", arguments: JSONValue.from(Args(threadId: threadId, modelSelection: modelSelection)))
    }

    public func interrupt(threadId: String) async throws {
        _ = try await mcp.callTool("t3_thread_interrupt", arguments: ["threadId": .string(threadId)])
    }

    struct Empty: Encodable {}
}
