import Foundation
import Observation
import TeaThreeKit

/// The hands-free conversation loop: listen → send to the Copilot → speak the
/// reply → listen again, until told to stop. The phone screen and CarPlay
/// both drive this same object.
@Observable
final class VoiceSession {
    enum Phase: Equatable {
        case idle
        case listening
        case thinking
        case speaking
    }

    struct Turn: Identifiable, Equatable {
        enum Role { case you, copilot, status }
        let id = UUID()
        let role: Role
        let text: String
    }

    private(set) var phase: Phase = .idle {
        didSet { if phase != oldValue { onPhaseChange?(phase) } }
    }
    private(set) var partial = ""
    private(set) var turns: [Turn] = []
    private(set) var isRunning = false

    /// CarPlay listens here to switch its voice-control states.
    @ObservationIgnored var onPhaseChange: ((Phase) -> Void)?

    @ObservationIgnored private let service: TeaThreeService
    @ObservationIgnored private let listener = SpeechListener()
    @ObservationIgnored private let speaker = Speaker()
    @ObservationIgnored private var loop: Task<Void, Never>?

    static let stopPhrases = ["stop listening", "goodbye", "good bye", "that's all", "that is all", "we're done", "never mind"]

    /// Supplies (and clears) photos to send with the next message.
    var takeAttachments: () -> [OutgoingAttachment] = { [] }

    init(service: TeaThreeService) {
        self.service = service
    }

    func toggle() {
        isRunning ? stop() : start()
    }

    func start() {
        guard loop == nil else { return }
        NaturalVoiceEngine.shared.prewarm()
        isRunning = true
        loop = Task { await run() }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        speaker.stop()
        isRunning = false
        partial = ""
        phase = .idle
        AudioSession.deactivate()
    }

    /// Typed messages use the same Copilot, without the mic.
    func sendTyped(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let photos = takeAttachments()
        guard !trimmed.isEmpty || !photos.isEmpty else { return }
        turns.append(Turn(role: .you, text: Self.label(trimmed, photos: photos.count)))
        await respond(to: trimmed, source: .typed, speak: false, attachments: photos)
    }

    private static func label(_ text: String, photos: Int) -> String {
        guard photos > 0 else { return text }
        let tag = photos == 1 ? "📷" : "📷×\(photos)"
        return text.isEmpty ? tag : "\(tag) \(text)"
    }

    // MARK: Loop

    private func run() async {
        defer {
            loop = nil
            isRunning = false
            phase = .idle
            AudioSession.deactivate()
        }
        guard await SpeechListener.requestAuthorization() else {
            note(SpeechListener.Failure.notAuthorized.localizedDescription)
            return
        }
        do {
            try AudioSession.activate()
        } catch {
            note("Couldn't start audio: \(error.localizedDescription)")
            return
        }

        let settings = service.store.settings
        while !Task.isCancelled {
            phase = .listening
            partial = ""
            Earcon.listening()
            let heard: String
            do {
                heard = try await listener.listen(silence: settings.endOfSpeechSilence) { text in
                    Task { @MainActor in self.partial = text }
                }
            } catch {
                note(error.localizedDescription)
                return
            }
            partial = ""
            guard !Task.isCancelled else { return }
            // Silence: keep listening. The point is that it's just *on*.
            guard !heard.isEmpty else { continue }
            Earcon.heard()

            if Self.isStopPhrase(heard) {
                await say("Okay.")
                return
            }
            let photos = takeAttachments()
            turns.append(Turn(role: .you, text: Self.label(heard, photos: photos.count)))
            await respond(to: heard, source: .voice, speak: settings.speakReplies, attachments: photos)
        }
    }

    private func respond(to text: String, source: CopilotPrompts.Source, speak: Bool, attachments: [OutgoingAttachment] = []) async {
        phase = .thinking
        let reply: String
        do {
            let copilot = try service.copilot()
            let blocked = Flag()
            let answer = try await copilot.ask(text, source: source, attachments: attachments) { event in
                switch event {
                case .working(let elapsed) where elapsed > 18 && elapsed < 40 && speak:
                    await self.say("Still working on it.", resume: .thinking)
                case .needsAttention:
                    blocked.set()
                default:
                    break
                }
            }
            if blocked.isSet {
                reply = "That's waiting on an approval in T3 Code."
            } else {
                reply = answer ?? "Done."
            }
        } catch is CancellationError {
            return
        } catch let error as T3Error {
            reply = error.spokenDescription
            if case .unauthorized = error { stop() }
        } catch {
            reply = "Something went wrong: \(error.localizedDescription)"
        }
        turns.append(Turn(role: .copilot, text: reply))
        if speak { await say(reply) }
    }

    private func say(_ text: String, resume: Phase? = nil) async {
        phase = .speaking
        await speaker.speak(text)
        if let resume { phase = resume }
    }

    private func note(_ text: String) {
        turns.append(Turn(role: .status, text: text))
    }

    static func isStopPhrase(_ text: String) -> Bool {
        let normalized = text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        return stopPhrases.contains { normalized == $0 || normalized == "okay \($0)" || normalized == "ok \($0)" }
    }
}

/// A set-once flag the Copilot event callback can flip from another task.
nonisolated final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    nonisolated var isSet: Bool { lock.withLock { value } }
    nonisolated func set() { lock.withLock { value = true } }
}
