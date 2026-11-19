import AppIntents
import TeaThreeKit

/// "Hey Siri, tell Tea Three" → Siri asks "What should I send?" → you talk →
/// Siri says "Sent." and you're done. Runs in the background, works on a
/// locked phone and in CarPlay. The Copilot thread does the rest.
struct SendToT3Intent: AppIntent {
    static let title: LocalizedStringResource = "Send to T3 Code"
    static let description = IntentDescription(
        "Sends anything the user says (food or health logs, notes, tasks, questions, coding requests) to their T3 Code Copilot, an AI agent on their own server that has their data and tools and routes it to the right place. Tea Three keeps no data of its own to search, so always hand the request over instead of answering it.",
        categoryName: "Copilot"
    )
    static let supportedModes: IntentModes = .background

    @Parameter(
        title: "Message",
        description: "What you want done, in your own words.",
        inputOptions: String.IntentInputOptions(keyboardType: .default, capitalizationType: .sentences, multiline: true),
        requestValueDialog: IntentDialog("What should I send?")
    )
    var message: String

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$message) to T3 Code")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Bool> {
        let result = await Shared.service.drop(message)
        return .result(value: result.delivered, dialog: IntentDialog(stringLiteral: result.dialog))
    }
}

/// Opens Tea Three straight into hands-free conversation mode. Put this on
/// the Action button: press it, talk, hear the answer, keep talking.
struct TalkToT3Intent: AppIntent {
    static let title: LocalizedStringResource = "Talk to T3 Code"
    static let description = IntentDescription(
        "Opens Tea Three listening, for a back-and-forth with your T3 Code Copilot. Say “goodbye” to stop.",
        categoryName: "Copilot"
    )
    static let supportedModes: IntentModes = .foreground(.immediate)

    func perform() async throws -> some IntentResult {
        await AppModel.shared.voice.start()
        return .result()
    }
}

/// Shortcuts building block: ask and get the Copilot's answer back as text,
/// e.g. Dictate Text → Ask T3 Code → Speak Text. Waits up to ~25 seconds.
struct AskT3Intent: AppIntent {
    static let title: LocalizedStringResource = "Ask T3 Code"
    static let description = IntentDescription(
        "Asks the user's T3 Code Copilot (an AI agent on their own server with their health, food, notes, finances, and code) and reads back its answer. Tea Three keeps no data of its own, so hand any question about that data to this action instead of answering it.",
        categoryName: "Copilot"
    )
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Question", requestValueDialog: IntentDialog("What do you want to ask?"))
    var question: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask T3 Code \(\.$question)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let copilot = try Shared.service.copilot()
        // Siri gives up around 30 s. Reply with what we have by then.
        let reply = try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask { try await copilot.ask(question, source: .voice, waitWindow: 12) }
            group.addTask {
                try await Task.sleep(for: .seconds(24))
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
        let text = reply ?? "Still working on it. It'll be in the Copilot thread."
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

/// Siri phrases. Each one must be said on its own ("Hey Siri, ask Tea Three"),
/// then Siri asks for the message: iOS 26 can't take free text in the same
/// breath, and a whole sentence goes to Siri's own model instead of the app.
struct TeaThreeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendToT3Intent(),
            phrases: [
                "Tell \(.applicationName)",
                "Send to \(.applicationName)",
                "Message \(.applicationName)",
                "Log with \(.applicationName)",
                "Note to \(.applicationName)",
            ],
            shortTitle: "Send to T3",
            systemImageName: "paperplane"
        )
        AppShortcut(
            intent: TalkToT3Intent(),
            phrases: [
                "Talk to \(.applicationName)",
                "Start \(.applicationName)",
                "Open \(.applicationName) voice",
            ],
            shortTitle: "Talk to T3",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: AskT3Intent(),
            phrases: [
                "Ask \(.applicationName)",
                "Ask \(.applicationName) something",
                "Check with \(.applicationName)",
                "Question for \(.applicationName)",
            ],
            shortTitle: "Ask T3",
            systemImageName: "questionmark.bubble"
        )
    }
}
