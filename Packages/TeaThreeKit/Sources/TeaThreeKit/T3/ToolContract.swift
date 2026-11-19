import Foundation

/// Everything Tea Three assumes about T3 Code's MCP tool surface, in one place.
///
/// T3 Code moves fast. Instead of hoping, `ToolContract.check` compares these
/// assumptions with the live `tools/list` schemas. It runs:
/// - in unit tests, against the recorded fixture for the last known-good version;
/// - in CI, nightly, against `t3@latest` and `t3@nightly` from npm;
/// - in the app's Settings ("Check compatibility"), against your own server.
public enum ToolContract {
    public struct Requirement: Sendable {
        public let tool: String
        /// Arguments Tea Three sends. Each must still exist in the input schema.
        public let arguments: [String]
        /// Enum values Tea Three sends, per argument. Each must still be allowed.
        public let enumValues: [String: [String]]
        /// If false, losing this tool degrades a feature instead of breaking pairing/sending.
        public let critical: Bool

        public init(_ tool: String, arguments: [String], enumValues: [String: [String]] = [:], critical: Bool = true) {
            self.tool = tool
            self.arguments = arguments
            self.enumValues = enumValues
            self.critical = critical
        }
    }

    public static let requirements: [Requirement] = [
        Requirement(
            "t3_thread_send",
            arguments: ["threadId", "message", "mode", "clientRequestId"],
            enumValues: ["mode": ["auto", "queue", "steer", "restart"]]
        ),
        Requirement(
            "t3_thread_launch",
            arguments: ["title", "message", "projectId", "scratch", "modelSelection", "runtimeMode", "clientRequestId"],
            enumValues: ["runtimeMode": RuntimeMode.allCases.map(\.rawValue)]
        ),
        Requirement("t3_thread_search", arguments: ["query", "limit"]),
        Requirement("t3_thread_read", arguments: ["threadId", "view", "limit", "maxCharsPerItem", "afterPosition"], enumValues: ["view": ["messages"]]),
        Requirement("t3_thread_wait", arguments: ["threadId", "runId", "timeoutMs"]),
        Requirement(
            "t3_thread_organize",
            arguments: ["threadId", "action", "snoozedUntil"],
            enumValues: ["action": ["pin", "archive", "settle", "snooze"]],
            critical: false
        ),
        Requirement("t3_thread_list", arguments: ["allProjects", "limit", "titleContains", "snoozed"], critical: false),
        Requirement("t3_thread_configure", arguments: ["threadId", "modelSelection"], critical: false),
        Requirement("t3_thread_interrupt", arguments: ["threadId"], critical: false),
        Requirement("t3_project_list", arguments: ["limit"], critical: false),
        Requirement("orchestrator_capabilities", arguments: [], critical: false),
    ]

    public struct Violation: Sendable, Hashable, CustomStringConvertible {
        public let tool: String
        public let critical: Bool
        public let problem: String

        public var description: String { "\(critical ? "BREAKING" : "degraded") \(tool): \(problem)" }
    }

    public static func check(_ tools: [MCPClient.Tool]) -> [Violation] {
        let byName = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var violations: [Violation] = []

        for requirement in requirements {
            guard let tool = byName[requirement.tool] else {
                violations.append(.init(tool: requirement.tool, critical: requirement.critical, problem: "tool is gone"))
                continue
            }
            let properties = tool.inputSchema?["properties"]?.objectValue ?? [:]
            for argument in requirement.arguments where properties[argument] == nil {
                violations.append(.init(tool: requirement.tool, critical: requirement.critical, problem: "argument `\(argument)` is gone"))
            }
            for (argument, values) in requirement.enumValues {
                guard let allowed = properties[argument]?["enum"]?.arrayValue?.compactMap(\.stringValue) else { continue }
                for value in values where !allowed.contains(value) {
                    violations.append(.init(
                        tool: requirement.tool,
                        critical: requirement.critical,
                        problem: "`\(argument)` no longer accepts \"\(value)\" (allowed: \(allowed.joined(separator: ", ")))"
                    ))
                }
            }
            // New required arguments we don't send would make every call fail.
            let required = tool.inputSchema?["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
            for argument in required where !requirement.arguments.contains(argument) {
                violations.append(.init(tool: requirement.tool, critical: requirement.critical, problem: "new required argument `\(argument)`"))
            }
        }
        return violations
    }
}
