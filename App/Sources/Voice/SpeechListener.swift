import AVFoundation
@preconcurrency import Speech
import TeaThreeKit

/// One turn of on-device speech-to-text. The turn ends when the speaker has
/// actually finished, not at the first pause:
/// - `TurnDetector` reads the transcript: a finished sentence ends after the
///   normal pause, "and", "um", a comma, or a fragment waits much longer, and
///   "send it" sends at once.
/// - The mic level counts too, against an adaptive noise floor, so a drawn-out
///   "ummm" (which the recognizer usually drops) keeps the turn open.
/// - A cue plays a second before sending; speaking again keeps listening.
/// - If the recognizer finalizes early, its text is kept and listening goes on.
nonisolated final class SpeechListener: @unchecked Sendable {
    enum Failure: LocalizedError {
        case notAuthorized
        case unavailable

        var errorDescription: String? {
            switch self {
            case .notAuthorized: "Tea Three needs microphone and speech recognition access. Turn them on in Settings."
            case .unavailable: "Speech recognition isn't available right now."
            }
        }
    }

    private static let maximumTurn: TimeInterval = 120

    private let recognizer = SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "tea-three.speech")
    private let audio = AudioInput()

    // Guarded by `queue`.
    private var continuation: CheckedContinuation<String, Error>?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var committed = ""
    private var latest = ""
    private var startedAt = Date()
    private var lastTextAt: Date?
    private var warned = false
    private var restarts = 0
    private var ticker: DispatchSourceTimer?
    private var detector = TurnDetector()
    private var onPartial: (@Sendable (String) -> Void)?
    private var onWarning: (@Sendable () -> Void)?

    static func requestAuthorization() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        let microphone = await AVAudioApplication.requestRecordPermission()
        return speech && microphone
    }

    /// Returns what was said once the turn ends (see the type comment), or ""
    /// if nothing is said within `noSpeechTimeout`.
    func listen(
        detector: TurnDetector,
        noSpeechTimeout: TimeInterval = 12,
        onPartial: @escaping @Sendable (String) -> Void,
        onWarning: @escaping @Sendable () -> Void = {}
    ) async throws -> String {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { throw Failure.notAuthorized }
        guard let recognizer, recognizer.isAvailable else { throw Failure.unavailable }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    self.begin(recognizer: recognizer, continuation: continuation, detector: detector,
                               noSpeechTimeout: noSpeechTimeout, onPartial: onPartial, onWarning: onWarning)
                }
            }
        } onCancel: {
            queue.async { self.finish(with: .success("")) }
        }
    }

    private func begin(
        recognizer: SFSpeechRecognizer,
        continuation: CheckedContinuation<String, Error>,
        detector: TurnDetector,
        noSpeechTimeout: TimeInterval,
        onPartial: @escaping @Sendable (String) -> Void,
        onWarning: @escaping @Sendable () -> Void
    ) {
        self.continuation = continuation
        self.detector = detector
        self.onPartial = onPartial
        self.onWarning = onWarning
        committed = ""
        latest = ""
        lastTextAt = nil
        warned = false
        restarts = 0
        startedAt = Date()
        audio.reset()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        let audio = audio
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            audio.handle(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            finish(with: .failure(error))
            return
        }
        startRecognition(recognizer)

        let ticker = DispatchSource.makeTimerSource(queue: queue)
        ticker.schedule(deadline: .now() + 0.1, repeating: 0.1)
        ticker.setEventHandler { [weak self] in self?.tick(noSpeechTimeout: noSpeechTimeout) }
        ticker.resume()
        self.ticker = ticker
    }

    /// Starts (or restarts, after the recognizer finalized early) a recognition
    /// segment. Earlier segments' text is kept in `committed`.
    private func startRecognition(_ recognizer: SFSpeechRecognizer) {
        generation += 1
        let mine = generation
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition {
            // Private, works offline, and has no one-minute server cap.
            request.requiresOnDeviceRecognition = true
        }
        audio.request = request

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            self.queue.async { [self] in
                guard self.continuation != nil, mine == self.generation else { return }
                if let text, !text.isEmpty {
                    let combined = self.committed.isEmpty ? text : "\(self.committed) \(text)"
                    if combined != self.latest {
                        self.latest = combined
                        self.lastTextAt = Date()
                        self.onPartial?(combined)
                    }
                }
                if isFinal || failed {
                    // The recognizer ended its segment on its own, often at a
                    // pause. Keep the words and keep listening; `tick` decides.
                    self.committed = self.latest
                    self.restarts += 1
                    guard self.restarts < 20 else {
                        self.finish(with: .success(TurnDetector.removingSendPhrase(self.latest)))
                        return
                    }
                    self.task?.cancel()
                    self.startRecognition(recognizer)
                }
            }
        }
    }

    private func tick(noSpeechTimeout: TimeInterval) {
        guard continuation != nil else { return }
        let now = Date()
        if now.timeIntervalSince(startedAt) > Self.maximumTurn {
            finish(with: .success(TurnDetector.removingSendPhrase(latest)))
            return
        }
        guard let lastTextAt else {
            if now.timeIntervalSince(startedAt) > noSpeechTimeout { finish(with: .success("")) }
            return
        }
        let sinceSound = audio.lastVoiceAt.map { now.timeIntervalSince($0) }
        switch detector.decide(latest, sinceText: now.timeIntervalSince(lastTextAt), sinceSound: sinceSound) {
        case .send:
            finish(with: .success(TurnDetector.removingSendPhrase(latest)))
        case .warn:
            if !warned {
                warned = true
                onWarning?()
            }
        case .listen:
            warned = false
        }
    }

    private func finish(with result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        generation += 1
        ticker?.cancel()
        ticker = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        audio.request?.endAudio()
        audio.request = nil
        task?.cancel()
        task = nil
        continuation.resume(with: result.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
    }
}

/// The mic tap's side: forwards audio to the current recognition request and
/// tracks voice activity against an adaptive noise floor (road noise, AC).
/// Called on the audio thread, so it's lock-protected.
nonisolated private final class AudioInput: @unchecked Sendable {
    private let lock = NSLock()
    private var _request: SFSpeechAudioBufferRecognitionRequest?
    private var _lastVoiceAt: Date?
    private var noiseFloor: Float = -50

    var request: SFSpeechAudioBufferRecognitionRequest? {
        get { lock.withLock { _request } }
        set { lock.withLock { _request = newValue } }
    }

    var lastVoiceAt: Date? { lock.withLock { _lastVoiceAt } }

    func reset() {
        lock.withLock {
            _lastVoiceAt = nil
            noiseFloor = -50
        }
    }

    func handle(_ buffer: AVAudioPCMBuffer) {
        let level = Self.level(of: buffer)
        lock.withLock {
            _request?.append(buffer)
            // Falls fast to quiet, rises slowly, so steady noise becomes the floor
            // while speech stands out above it.
            noiseFloor = level < noiseFloor ? level : noiseFloor + (level - noiseFloor) * 0.005
            if level > noiseFloor + 12, level > -52 { _lastVoiceAt = Date() }
        }
    }

    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return -100 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += channel[index] * channel[index] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        return 20 * log10(max(rms, 1e-6))
    }
}
