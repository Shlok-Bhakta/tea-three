import Foundation

/// User preferences for the Copilot thread. Stored in the shared app group so
/// the app, the App Intents, and CarPlay all agree.
public struct CopilotSettings: Sendable, Codable, Equatable {
    /// The pinned thread's exact title. Tea Three finds the thread by this name
    /// if it loses the cached id (new phone, re-pair, thread recreated by hand).
    public var threadTitle: String
    /// Model for the Copilot itself. `nil` means "the server's default".
    public var copilotModel: ModelSelection?
    /// Model the Copilot should use for threads it starts. `nil`: its own choice.
    public var workerModel: ModelSelection?
    /// Project that hosts the Copilot thread. `nil` = a scratch folder.
    public var projectId: String?
    public var runtimeMode: RuntimeMode?
    /// Free-form extra instructions appended to the briefing ("my food log lives in ~/Notes/food.md").
    public var extraInstructions: String
    /// Speak replies in voice mode.
    public var speakReplies: Bool
    /// Seconds of silence that end an utterance in voice mode.
    public var endOfSpeechSilence: Double

    public init(
        threadTitle: String = "Tea Three Copilot",
        copilotModel: ModelSelection? = nil,
        workerModel: ModelSelection? = nil,
        projectId: String? = nil,
        runtimeMode: RuntimeMode? = nil,
        extraInstructions: String = "",
        speakReplies: Bool = true,
        endOfSpeechSilence: Double = 1.6
    ) {
        self.threadTitle = threadTitle
        self.copilotModel = copilotModel
        self.workerModel = workerModel
        self.projectId = projectId
        self.runtimeMode = runtimeMode
        self.extraInstructions = extraInstructions
        self.speakReplies = speakReplies
        self.endOfSpeechSilence = endOfSpeechSilence
    }

    public static let `default` = CopilotSettings()
}
