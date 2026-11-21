import Foundation
import Observation
import TeaThreeKit

/// The hands-free conversation loop: listen → send to the Copilot → speak the
/// reply → listen again, until told to stop. The phone screen and CarPlay
/// both drive this same object.
///
/// Listening doesn't pause while the Copilot works: anything said (or typed)
/// meanwhile steers the running request, like interrupting a person
/// mid-sentence, and "cancel that" stops it. The reply is read out once the
/// speaker isn't mid-sentence.
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
        /// Where one of your messages is, shown under it.
        enum Delivery: Equatable {
            case sending
            case delivered
            /// Sent while the Copilot was working; it took it as a mid-task update.
            case steered
            /// Saved; sends when the server is back.
            case queued
            case failed
        }
        let id = UUID()
        let role: Role
        let text: String
        var delivery: Delivery?
    }

    private(set) var phase: Phase = .idle {
        didSet { if phase != oldValue { onPhaseChange?(phase) } }
    }
    private(set) var partial = ""
    private(set) var turns: [Turn] = []
    private(set) var isRunning = false
    /// The Copilot is working on a request; anything sent now steers it.
    private(set) var isWorking = false

    /// CarPlay listens here to switch its voice-control states.
    @ObservationIgnored var onPhaseChange: ((Phase) -> Void)?

    @ObservationIgnored private let service: TeaThreeService
    @ObservationIgnored private let listener = SpeechListener()
    @ObservationIgnored private let speaker = Speaker()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var work: Task<Void, Never>?
    /// Replies that came back while you were talking, read out when you finish.
    @ObservationIgnored private var unspoken: [String] = []

    static let stopPhrases = ["stop listening", "goodbye", "good bye", "that's all", "that is all", "we're done"]
    static let cancelPhrases = ["cancel", "cancel that", "stop that", "scratch that", "never mind", "nevermind", "stop", "stop it"]

    /// Supplies (and clears) photos to send with the next message.
    @ObservationIgnored var takeAttachments: () -> [OutgoingAttachment] = { [] }
    /// The status light's last word: lets a send fail fast instead of hanging.
    @ObservationIgnored var isOffline: () -> Bool = { false }
    /// Called when a message couldn't reach the server, so the light rechecks.
    @ObservationIgnored var onDeliveryProblem: () -> Void = {}

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

    /// Stops listening. A request in progress keeps running in T3 Code.
    func stop() {
        loop?.cancel()
        loop = nil
        speaker.stop()
        unspoken = []
        isRunning = false
        partial = ""
        phase = isWorking ? .thinking : .idle
        AudioSession.deactivate()
    }

    /// Typed messages use the same Copilot, without the mic. While it's
    /// working they steer it, same as speaking.
    func sendTyped(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let photos = takeAttachments()
        guard !trimmed.isEmpty || !photos.isEmpty else { return }
        await submit(trimmed, source: .typed, speak: isRunning && service.store.settings.speakReplies, attachments: photos)
    }

    /// Stops the request the Copilot is working on.
    func interrupt() async {
        guard isWorking else { return }
        work?.cancel()
        work = nil
        isWorking = false
        if !isRunning { phase = .idle }
        do {
            try await service.copilot().interrupt()
            turns.append(Turn(role: .status, text: "Stopped."))
        } catch {
            turns.append(Turn(role: .status, text: "Couldn't stop it: \(error.localizedDescription)"))
        }
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
            phase = isWorking ? .thinking : .idle
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
            while !unspoken.isEmpty, !Task.isCancelled {
                await say(unspoken.removeFirst())
            }
            phase = .listening
            partial = ""
            if !isWorking { Earcon.listening() }
            let heard: String
            do {
                heard = try await listener.listen(detector: settings.turnDetector) { text in
                    Task { @MainActor in self.partial = text }
                } onWarning: {
                    // About to send: a soft tick and tap. Keep talking to hold the turn.
                    Task { @MainActor in Earcon.aboutToSend() }
                }
            } catch {
                note(error.localizedDescription)
                return
            }
            partial = ""
            guard !Task.isCancelled else { return }
            // Silence, or a reply is ready: go round again.
            guard !heard.isEmpty else { continue }
            Earcon.heard()

            if Self.matches(heard, Self.stopPhrases) {
                await say("Okay.")
                return
            }
            if isWorking, Self.matches(heard, Self.cancelPhrases) {
                await interrupt()
                await say("Stopped.")
                continue
            }
            await submit(heard, source: .voice, speak: settings.speakReplies, attachments: takeAttachments())
        }
    }

    // MARK: Sending

    /// A new request, or a steer if the Copilot is already working on one.
    private func submit(_ text: String, source: CopilotPrompts.Source, speak: Bool, attachments: [OutgoingAttachment]) async {
        let turn = Turn(role: .you, text: Self.label(text, photos: attachments.count), delivery: .sending)
        turns.append(turn)
        if isWorking {
            await steer(text, turn: turn.id, source: source, attachments: attachments, speak: speak)
        } else {
            startWork(text, turn: turn.id, source: source, speak: speak, attachments: attachments)
        }
    }

    private func steer(_ text: String, turn: UUID, source: CopilotPrompts.Source, attachments: [OutgoingAttachment], speak: Bool) async {
        do {
            try await service.copilot().steer(text, source: source, attachments: attachments)
            mark(turn, .steered)
        } catch let error as T3Error {
            if case .transport = error {
                await undelivered(text, turn: turn, attachments: attachments, speak: speak)
            } else {
                mark(turn, .failed)
                note(error.errorDescription ?? "Couldn't send that.")
            }
        } catch is URLError {
            await undelivered(text, turn: turn, attachments: attachments, speak: speak)
        } catch {
            mark(turn, .failed)
            note(error.localizedDescription)
        }
    }

    /// Sends and waits for the reply in the background, so listening (and
    /// steering) carries on meanwhile.
    private func startWork(_ text: String, turn: UUID, source: CopilotPrompts.Source, speak: Bool, attachments: [OutgoingAttachment]) {
        isWorking = true
        if !isRunning { phase = .thinking }
        work = Task {
            let reply = await respond(to: text, turn: turn, source: source, attachments: attachments, speak: speak)
            guard !Task.isCancelled else { return }
            work = nil
            isWorking = false
            if !isRunning, phase == .thinking { phase = .idle }
            guard let reply else { return }
            turns.append(Turn(role: reply.role, text: reply.text))
            guard speak else { return }
            if isRunning {
                // Read it out between turns, not over someone mid-sentence.
                unspoken.append(reply.text)
                listener.yieldIfSilent()
            } else {
                await say(reply.text)
                phase = .idle
            }
        }
    }

    /// The Copilot's answer (or a status line), or nil when cancelled.
    private func respond(to text: String, turn: UUID, source: CopilotPrompts.Source, attachments: [OutgoingAttachment], speak: Bool) async -> (role: Turn.Role, text: String)? {
        // Known offline and still not answering: save it rather than wait out a timeout.
        if isOffline(), await !service.checkConnection(timeout: 3).isConnected {
            return undeliveredReply(text, turn: turn, attachments: attachments)
        }
        do {
            let copilot = try service.copilot()
            let blocked = Flag()
            let answer = try await copilot.ask(text, source: source, attachments: attachments) { event in
                switch event {
                case .sent:
                    await self.mark(turn, .delivered)
                case .needsAttention:
                    blocked.set()
                default:
                    break
                }
            }
            if blocked.isSet { return (.copilot, "That's waiting on an approval in T3 Code.") }
            return (.copilot, answer ?? "Done.")
        } catch is CancellationError {
            return nil
        } catch let error as T3Error {
            if case .transport = error, delivery(of: turn) == .sending {
                return undeliveredReply(text, turn: turn, attachments: attachments)
            }
            if delivery(of: turn) == .sending { mark(turn, .failed) }
            if case .unauthorized = error { stop() }
            return (.copilot, error.spokenDescription)
        } catch is URLError where delivery(of: turn) == .sending {
            return undeliveredReply(text, turn: turn, attachments: attachments)
        } catch {
            if Task.isCancelled { return nil }
            if delivery(of: turn) == .sending { mark(turn, .failed) }
            return (.copilot, "Something went wrong: \(error.localizedDescription)")
        }
    }

    /// The server can't be reached. Words wait in the outbox and go out when it's
    /// back; photos can't, so those are reported as not sent.
    private func undeliveredReply(_ text: String, turn: UUID, attachments: [OutgoingAttachment]) -> (role: Turn.Role, text: String) {
        onDeliveryProblem()
        if attachments.isEmpty, !text.isEmpty {
            // Sent later, when nobody's waiting on the reply: same as a Siri drop.
            service.store.enqueue(text, source: .siri)
            mark(turn, .queued)
            return (.status, "Can't reach T3 Code right now. I saved that and will send it when you're connected.")
        }
        mark(turn, .failed)
        return (.status, "Can't reach T3 Code right now, so that wasn't sent. Try again once you're connected.")
    }

    private func undelivered(_ text: String, turn: UUID, attachments: [OutgoingAttachment], speak: Bool) async {
        let reply = undeliveredReply(text, turn: turn, attachments: attachments)
        turns.append(Turn(role: reply.role, text: reply.text))
        if speak { await say(reply.text) }
    }

    private func mark(_ turn: UUID, _ delivery: Turn.Delivery) {
        guard let index = turns.firstIndex(where: { $0.id == turn }) else { return }
        turns[index].delivery = delivery
    }

    private func delivery(of turn: UUID) -> Turn.Delivery? {
        turns.first { $0.id == turn }?.delivery
    }

    private func say(_ text: String) async {
        let resume = phase
        phase = .speaking
        await speaker.speak(text)
        phase = resume == .speaking ? .idle : resume
    }

    private func note(_ text: String) {
        turns.append(Turn(role: .status, text: text))
    }

    static func matches(_ text: String, _ phrases: [String]) -> Bool {
        let normalized = text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        return phrases.contains { normalized == $0 || normalized == "okay \($0)" || normalized == "ok \($0)" }
    }
}

/// A set-once flag the Copilot event callback can flip from another task.
nonisolated final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    nonisolated var isSet: Bool { lock.withLock { value } }
    nonisolated func set() { lock.withLock { value = true } }
}
