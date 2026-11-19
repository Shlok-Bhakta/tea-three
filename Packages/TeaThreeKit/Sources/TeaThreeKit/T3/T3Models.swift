import Foundation

// Shapes of the T3 Code MCP tools Tea Three uses. Only the fields we read are
// declared, and almost all are optional: T3 adds fields constantly, and the
// contract tests (not the decoders) are what flag removals.

public struct ModelSelection: Sendable, Codable, Hashable {
    public var provider: String?
    public var instanceId: String?
    public var model: String
    public var options: [String: JSONValue]?

    public init(provider: String? = nil, instanceId: String? = nil, model: String, options: [String: JSONValue]? = nil) {
        self.provider = provider
        self.instanceId = instanceId
        self.model = model
        self.options = options
    }
}

public enum RuntimeMode: String, Sendable, Codable, CaseIterable {
    case approvalRequired = "approval-required"
    case autoAcceptEdits = "auto-accept-edits"
    case auto
    case fullAccess = "full-access"
}

public enum SendMode: String, Sendable, Codable {
    /// Start an idle thread, steer a running turn, or queue.
    case auto
    case queue
    case steer
    case restart
}

public enum OrganizeAction: String, Sendable, Codable {
    case pin, unpin, snooze, unsnooze, settle, unsettle, archive, unarchive
    case markUnread = "mark_unread"
}

public struct ThreadSummary: Sendable, Codable, Hashable, Identifiable {
    public let threadId: String
    public let projectId: String?
    public let title: String
    public let link: String?
    public let status: String?
    public let model: String?
    public let providerInstanceId: String?
    public let settled: Bool?
    public let snoozed: Bool?
    public let archived: Bool?
    public let updatedAt: String?

    public var id: String { threadId }
}

public struct ThreadListResult: Sendable, Codable {
    public let threads: [ThreadSummary]
    public let nextCursor: Int?
    public let total: Int?
}

public struct ThreadSearchResult: Sendable, Codable {
    public struct Match: Sendable, Codable, Hashable {
        public let threadId: String
        public let projectId: String?
        public let title: String
        public let link: String?
        public let source: String?
    }

    public let matches: [Match]
}

public struct ThreadLaunchResult: Sendable, Codable {
    public let threadId: String
    public let link: String?
    public let projectId: String?
    public let runId: String?
    public let status: String?
}

public struct ThreadSendResult: Sendable, Codable {
    public let threadId: String
    public let messageId: String?
    public let runId: String?
    public let status: String?
    /// `started`, `queued`, `steered`, ... (free-form on purpose).
    public let delivery: String?
    public let taskId: String?
}

public struct ThreadWaitResult: Sendable, Codable {
    public let threadId: String
    public let runId: String?
    public let status: String?
    public let timedOut: Bool?
}

public struct ThreadReadResult: Sendable, Codable {
    public struct Thread: Sendable, Codable {
        public let threadId: String
        public let title: String
        public let status: String?
        public let latestRunId: String?
        public let activeRunId: String?
        public let archived: Bool?
        public let settled: Bool?
        public let snoozed: Bool?
        public let pendingRequestCount: Int?
    }

    public struct Item: Sendable, Codable, Hashable {
        public let position: Int
        public let itemId: String?
        public let runId: String?
        /// `user_message`, `assistant_message`, `plan`, ... in the `messages` view.
        public let type: String
        public let status: String?
        public let text: String?
        public let textTruncated: Bool?
        /// Newer servers mark `commentary` / `partial_answer` / `final_answer`.
        public let phase: String?
    }

    public let thread: Thread
    public let items: [Item]
    public let nextPosition: Int?
    public let hasMore: Bool?

    /// The last assistant message of a run, which is the "answer" to speak.
    public func finalAssistantText(runId: String? = nil) -> String? {
        let candidates = items.filter { $0.type == "assistant_message" && (runId == nil || $0.runId == runId) }
        let finals = candidates.filter { $0.phase == "final_answer" }
        return (finals.isEmpty ? candidates : finals).max(by: { $0.position < $1.position })?.text
    }
}

public struct ProjectListResult: Sendable, Codable {
    public struct Project: Sendable, Codable, Hashable, Identifiable {
        public let projectId: String
        public let title: String?
        public let name: String?
        public let workspaceRoot: String?

        public var id: String { projectId }
        public var displayName: String { title ?? name ?? workspaceRoot ?? projectId }

        enum CodingKeys: String, CodingKey {
            case projectId, id, title, name, workspaceRoot
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Tolerate `id` or `projectId`; T3 has used both across tools.
            projectId = try container.decodeIfPresent(String.self, forKey: .projectId)
                ?? container.decode(String.self, forKey: .id)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            workspaceRoot = try container.decodeIfPresent(String.self, forKey: .workspaceRoot)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(projectId, forKey: .projectId)
            try container.encodeIfPresent(title, forKey: .title)
            try container.encodeIfPresent(name, forKey: .name)
            try container.encodeIfPresent(workspaceRoot, forKey: .workspaceRoot)
        }
    }

    public let projects: [Project]
    public let nextCursor: Int?
}

/// Output of `orchestrator_capabilities`, trimmed to what the model picker needs.
public struct OrchestratorCapabilities: Sendable, Codable {
    public struct Provider: Sendable, Codable, Hashable, Identifiable {
        public struct Model: Sendable, Codable, Hashable, Identifiable {
            /// A per-model setting such as reasoning effort or fast mode.
            /// Values are strings or booleans; T3 adds new options over time.
            public struct Option: Sendable, Codable, Hashable, Identifiable {
                public let id: String
                public let values: [JSONValue]
                public let `default`: JSONValue?

                public var isToggle: Bool { values.allSatisfy { if case .bool = $0 { true } else { false } } }
            }

            public let id: String
            public let label: String?
            public let options: [Option]?
            public var displayName: String { label ?? id }
        }

        public let providerInstanceId: String
        public let driverKind: String?
        public let displayName: String?
        public let models: [Model]

        public var id: String { providerInstanceId }
    }

    public let runtimeMode: String?
    public let providers: [Provider]

    /// The provider and model a selection points at, if the server still lists it.
    public func lookup(_ selection: ModelSelection) -> (provider: Provider, model: Provider.Model)? {
        let instance = selection.instanceId ?? selection.provider
        for provider in providers where instance == nil || provider.providerInstanceId == instance {
            if let model = provider.models.first(where: { $0.id == selection.model }) { return (provider, model) }
        }
        return nil
    }

    /// The first model listed, for tests and tools that need *a* model to launch an idle thread.
    public var firstModel: ModelSelection? {
        providers.first { !$0.models.isEmpty }.map { ModelSelection(instanceId: $0.providerInstanceId, model: $0.models[0].id) }
    }
}

// MARK: - Attachments

/// A photo (or file) to send with a message. JPEG/PNG/GIF/WebP, at most 10 MB.
public struct OutgoingAttachment: Sendable, Equatable {
    public var data: Data
    public var name: String
    public var mimeType: String

    public init(data: Data, name: String, mimeType: String) {
        self.data = data
        self.name = name
        self.mimeType = mimeType
    }

    public var isImage: Bool { mimeType.hasPrefix("image/") }
}

/// An uploaded attachment, as `t3_thread_send_attachments` wants it.
public struct UploadedAttachment: Sendable, Codable, Equatable {
    public let type: String
    public let id: String
    public let name: String
    public let mimeType: String
    public let sizeBytes: Int
}

public struct AttachmentUploadTicket: Sendable, Codable {
    public let attachmentId: String
    /// Pre-signed path on the server's origin. POST the raw bytes there; no auth header.
    public let relativeUrl: String
}
