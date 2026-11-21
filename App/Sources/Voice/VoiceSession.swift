import Foundation
import Observation
import UIKit
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
    /// Press-and-hold to talk is in progress.
    private(set) var isHolding = false

    /// CarPlay listens here to switch its voice-control states.
    @ObservationIgnored var onPhaseChange: ((Phase) -> Void)?

    @ObservationIgnored private let service: TeaThreeService
    @ObservationIgnored private let listener = SpeechListener()
    @ObservationIgnored private let speaker = Speaker()
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// A single press-and-hold turn while hands-free is off.
    @ObservationIgnored private var holdTurn: Task<Void, Never>?
    /// A press that came in while `holdTurn` was still finishing the previous one.
    @ObservationIgnored private var pendingHold = false
    @ObservationIgnored private var work: Task<Void, Never>?
    /// The message that started the current work, for its delivery label.
    @ObservationIgnored private var workTurn: UUID?
    /// Turns a steer started because the previous one had just ended. Their
    /// replies are awaited after the current one.
    @ObservationIgnored private var followUps: [FollowUp] = []
    /// Queued messages by retry key, so their label updates when the outbox sends them.
    @ObservationIgnored private var queuedTurns: [String: UUID] = [:]
    /// A Stop in flight; new messages wait for it, so they aren't stopped too.
    @ObservationIgnored private var stopping: Task<Bool, Never>?
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
        guard loop == nil, holdTurn == nil else { return }
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

    // MARK: Press and hold

    /// Listens with no end-of-turn cutoff until `endHold()`. With hands-free on,
    /// it holds the current turn open (and cuts off a reply being read out);
    /// with it off, it's a one-off turn.
    func beginHold() {
        guard !isHolding else { return }
        isHolding = true
        listener.hold()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        // Talking over a reply cuts it off; the rest stays on screen.
        if phase == .speaking {
            unspoken = []
            speaker.stop()
        }
        if isRunning { return }
        guard holdTurn == nil else {
            pendingHold = true
            return
        }
        holdTurn = Task { await holdOnce() }
    }

    func endHold() {
        guard isHolding else { return }
        isHolding = false
        listener.releaseHold()
    }

    private func holdOnce() async {
        let heard = await captureHeld()
        // The mic is closed: a new hold can start while this one is being sent.
        holdTurn = nil
        partial = ""
        // Pressed again while this turn was still finalizing: listen for that one now.
        // Only for a new press, so a mic that fails to start isn't retried in a loop.
        if pendingHold, isHolding, !isRunning {
            holdTurn = Task { await holdOnce() }
        }
        pendingHold = false
        if !isRunning, holdTurn == nil {
            if phase == .listening { phase = isWorking ? .thinking : .idle }
            if heard.isEmpty, !isWorking { AudioSession.deactivate() }
        }
        guard !heard.isEmpty else { return }
        Earcon.heard()
        let settings = service.store.settings
        await submit(heard, source: .voice, speak: settings.speakReplies, attachments: takeAttachments())
    }

    /// One held turn of listening; "" if nothing was said or the mic couldn't start.
    private func captureHeld() async -> String {
        guard await SpeechListener.requestAuthorization() else {
            note(SpeechListener.Failure.notAuthorized.localizedDescription)
            return ""
        }
        do {
            try AudioSession.activate()
        } catch {
            note("Couldn't start audio: \(error.localizedDescription)")
            return ""
        }
        phase = .listening
        Earcon.listening()
        do {
            return try await listener.listen(detector: service.store.settings.turnDetector) { text in
                Task { @MainActor in self.partial = text }
            }
        } catch {
            note(error.localizedDescription)
            return ""
        }
    }

    /// Typed messages use the same Copilot, without the mic. While it's
    /// working they steer it, same as speaking.
    func sendTyped(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let photos = takeAttachments()
        guard !trimmed.isEmpty || !photos.isEmpty else { return }
        await submit(trimmed, source: .typed, speak: isRunning && service.store.settings.speakReplies, attachments: photos)
    }

    /// Stops the request the Copilot is working on. True if it was stopped.
    @discardableResult
    func interrupt() async -> Bool {
        if let stopping { return await stopping.value }
        guard isWorking else { return false }
        let task = Task { () -> Bool in
            do {
                // No Copilot thread yet means the first message is still being set up.
                guard try await service.copilot().interrupt() else {
                    note("Can't stop it yet, it's still starting.")
                    return false
                }
            } catch {
                note("Couldn't stop it: \(error.localizedDescription)")
                return false
            }
            work?.cancel()
            work = nil
            followUps = []
            isWorking = false
            if let workTurn, delivery(of: workTurn) == .sending { mark(workTurn, .failed) }
            if !isRunning { phase = .idle }
            note("Stopped.")
            return true
        }
        stopping = task
        defer { stopping = nil }
        return await task.value
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
            // Not during a hold: the mic opens first, replies wait.
            while !unspoken.isEmpty, !Task.isCancelled, !isHolding {
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
                await say(await interrupt() ? "Stopped." : "I couldn't stop it.")
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
        if !text.isEmpty { SendMessageHandler.donate(text) }
        _ = await stopping?.value
        if isWorking {
            await steer(text, turn: turn.id, source: source, attachments: attachments, speak: speak)
        } else {
            startWork(text, turn: turn.id, source: source, speak: speak, attachments: attachments)
        }
    }

    private func steer(_ text: String, turn: UUID, source: CopilotPrompts.Source, attachments: [OutgoingAttachment], speak: Bool) async {
        let requestID = UUID().uuidString
        if await isUnreachable() {
            guard !Task.isCancelled else { return }
            await undelivered(text, turn: turn, requestID: requestID, attachments: attachments, speak: speak)
            return
        }
        // If this starts a new turn, its reply comes after here. Taken before sending,
        // since the current turn's lookup may move the shared read position past it.
        let readFrom = service.store.copilotThreadID.flatMap { service.store.readCursor(threadId: $0) } ?? 0
        do {
            let sent = try await service.copilot().steer(text, source: source, attachments: attachments, requestID: requestID)
            guard sent.delivery != "steered" else {
                mark(turn, .steered)
                return
            }
            // The turn had just ended, so this started (or queued) a new one: wait for its reply too.
            mark(turn, .delivered)
            // A Stop in flight clears follow-ups; decide after it, so this run isn't dropped.
            _ = await stopping?.value
            let followUp = FollowUp(sent: sent, readFrom: readFrom)
            if isWorking {
                followUps.append(followUp)
            } else {
                startWork(turn: turn, speak: speak) { await self.follow(followUp) }
            }
        } catch _ where Task.isCancelled {
            return
        } catch T3Error.transport {
            await undelivered(text, turn: turn, requestID: requestID, attachments: attachments, speak: speak)
        } catch is URLError {
            await undelivered(text, turn: turn, requestID: requestID, attachments: attachments, speak: speak)
        } catch {
            mark(turn, .failed)
            note((error as? T3Error)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Sends and waits for the reply in the background, so listening (and
    /// steering) carries on meanwhile.
    private func startWork(_ text: String, turn: UUID, source: CopilotPrompts.Source, speak: Bool, attachments: [OutgoingAttachment]) {
        startWork(turn: turn, speak: speak) {
            await self.respond(to: text, turn: turn, source: source, attachments: attachments)
        }
    }

    private func startWork(turn: UUID, speak: Bool, first: @escaping () async -> Reply?) {
        isWorking = true
        workTurn = turn
        if !isRunning { phase = .thinking }
        work = Task {
            var reply = await first()
            while !Task.isCancelled {
                if let reply { await publish(reply, speak: speak) }
                guard !followUps.isEmpty else { break }
                reply = await follow(followUps.removeFirst())
            }
            guard !Task.isCancelled else { return }
            work = nil
            isWorking = false
            if !isRunning, phase == .thinking { phase = .idle }
            // A press-and-hold turn left the mic session up for the reply.
            if !isRunning, holdTurn == nil { AudioSession.deactivate() }
        }
    }

    private func publish(_ reply: Reply, speak: Bool) async {
        turns.append(Turn(role: reply.role, text: reply.text))
        guard speak else { return }
        if isRunning {
            // Read it out between turns, not over someone mid-sentence.
            unspoken.append(reply.text)
            listener.yieldIfSilent()
        } else if holdTurn == nil {
            // Not while a press-and-hold has the mic open; it's on screen either way.
            await say(reply.text)
        }
    }

    struct FollowUp {
        let sent: ThreadSendResult
        let readFrom: Int
    }

    /// The reply to a turn a steer started.
    private func follow(_ followUp: FollowUp) async -> Reply? {
        let sent = followUp.sent
        do {
            let blocked = Flag()
            let answer = try await service.copilot().awaitReply(threadId: sent.threadId, runId: sent.runId, readingAfter: followUp.readFrom) { event in
                if case .needsAttention = event { blocked.set() }
            }
            if blocked.isSet { return (.copilot, "That's waiting on an approval in T3 Code.") }
            return (.copilot, answer ?? "Done.")
        } catch {
            return Task.isCancelled ? nil : (.copilot, "Something went wrong: \(error.localizedDescription)")
        }
    }

    typealias Reply = (role: Turn.Role, text: String)

    /// The Copilot's answer (or a status line), or nil when cancelled.
    private func respond(to text: String, turn: UUID, source: CopilotPrompts.Source, attachments: [OutgoingAttachment]) async -> Reply? {
        // One retry key for the live send and any queued retry of it.
        let requestID = UUID().uuidString
        if await isUnreachable() {
            guard !Task.isCancelled else { return nil }
            return undeliveredReply(text, turn: turn, requestID: requestID, attachments: attachments)
        }
        do {
            let copilot = try service.copilot()
            let blocked = Flag()
            let answer = try await copilot.ask(text, source: source, attachments: attachments, requestID: requestID) { event in
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
        } catch _ where Task.isCancelled {
            // Stopped (URLSession reports that as a transport error): not an offline send.
            return nil
        } catch is CancellationError {
            return nil
        } catch let error as T3Error {
            if case .transport = error, delivery(of: turn) == .sending {
                return undeliveredReply(text, turn: turn, requestID: requestID, attachments: attachments)
            }
            if delivery(of: turn) == .sending { mark(turn, .failed) }
            if case .unauthorized = error { stop() }
            return (.copilot, error.spokenDescription)
        } catch is URLError where delivery(of: turn) == .sending {
            return undeliveredReply(text, turn: turn, requestID: requestID, attachments: attachments)
        } catch {
            if delivery(of: turn) == .sending { mark(turn, .failed) }
            return (.copilot, "Something went wrong: \(error.localizedDescription)")
        }
    }

    /// The server can't be reached. Words wait in the outbox and go out when it's
    /// back; photos can't, so those are reported as not sent.
    private func undeliveredReply(_ text: String, turn: UUID, requestID: String, attachments: [OutgoingAttachment]) -> Reply {
        defer { onDeliveryProblem() }
        if attachments.isEmpty, !text.isEmpty {
            // Sent later, when nobody's waiting on the reply: same as a Siri drop.
            service.store.enqueue(text, source: .siri, id: requestID)
            mark(turn, .queued)
            queuedTurns[requestID] = turn
            return (.status, "Can't reach T3 Code right now. I saved that and will send it when you're connected.")
        }
        mark(turn, .failed)
        return (.status, "Can't reach T3 Code right now, so that wasn't sent. Try again once you're connected.")
    }

    private func undelivered(_ text: String, turn: UUID, requestID: String, attachments: [OutgoingAttachment], speak: Bool) async {
        await publish(undeliveredReply(text, turn: turn, requestID: requestID, attachments: attachments), speak: speak)
    }

    /// Known offline and still not answering: save the message rather than wait out a timeout.
    private func isUnreachable() async -> Bool {
        guard isOffline() else { return false }
        return await !service.checkConnection(timeout: 3).isConnected
    }

    /// The outbox sent (true) or gave up on (false) some queued messages.
    func outboxSettled(_ outcomes: [String: Bool]) {
        for (id, sent) in outcomes {
            guard let turn = queuedTurns.removeValue(forKey: id) else { continue }
            mark(turn, sent ? .delivered : .failed)
        }
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
