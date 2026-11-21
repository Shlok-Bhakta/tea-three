import AVFoundation
import Speech
import TeaThreeKit

/// One turn of on-device speech-to-text, on iOS 26's `SpeechAnalyzer` with
/// `SpeechTranscriber`: the long-form model behind Notes and Voice Memos, and
/// what T3 Code's own app transcribes with. It has no time limit, finalized
/// text is kept as it arrives (so a five-minute ramble comes through whole),
/// and nothing is censored.
///
/// The turn ends when the speaker has actually finished, not at the first pause:
/// - `TurnDetector` reads the transcript: a finished sentence ends after the
///   normal pause, "and", "um", a comma, or a fragment waits much longer, and
///   "send it" sends at once.
/// - The mic level counts too, against an adaptive noise floor, so a drawn-out
///   "ummm" (which the transcriber drops) keeps the turn open.
/// - A cue plays a second before sending; speaking again keeps listening.
/// - When the turn ends, the analyzer finalizes everything it heard before the
///   text is returned, so the last words aren't left in a rough draft.
nonisolated final class SpeechListener: @unchecked Sendable {
    enum Failure: LocalizedError {
        case notAuthorized
        case unavailable
        case unsupportedLanguage

        var errorDescription: String? {
            switch self {
            case .notAuthorized: "Tea Three needs microphone and speech recognition access. Turn them on in Settings."
            case .unavailable: "Speech recognition isn't available right now."
            case .unsupportedLanguage: "On-device transcription doesn't support this phone's language yet."
            }
        }
    }

    private static let maximumTurn: TimeInterval = 15 * 60

    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "tea-three.speech")
    private let audio = AudioInput()

    // Guarded by `queue`.
    private var continuation: CheckedContinuation<String, Error>?
    private var current: Listen?
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?
    /// A reply is ready: end the turn as soon as it's clear nobody is talking.
    private var yieldRequested = false
    private var latest = ""
    private var startedAt = Date()
    private var lastTextAt: Date?
    private var warned = false
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

    /// The phone's language, as the transcriber knows it, with its model installed.
    private static func transcriber() async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable else { throw Failure.unavailable }
        var locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current)
        if locale == nil { locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) }
        guard let locale else { throw Failure.unsupportedLanguage }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        // First use downloads the language model (shared with the system, so
        // usually already there from dictation or Notes).
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        return transcriber
    }

    /// Returns what was said once the turn ends (see the type comment), or ""
    /// if nothing is said within `noSpeechTimeout` or `yieldIfSilent()` is called first.
    func listen(
        detector: TurnDetector,
        noSpeechTimeout: TimeInterval = 30,
        onPartial: @escaping @Sendable (String) -> Void,
        onWarning: @escaping @Sendable () -> Void = {}
    ) async throws -> String {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { throw Failure.notAuthorized }

        let transcriber = try await Self.transcriber()
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .lingering))
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw Failure.unavailable
        }
        try await analyzer.prepareToAnalyze(in: format)
        let (inputs, feed) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        try await analyzer.start(inputSequence: inputs)

        // Owns this turn's transcript, and records a cancel that lands before
        // `begin` (so the mic never starts for a listen that was already stopped).
        let listen = Listen()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    self.begin(
                        listen, analyzer: analyzer, transcriber: transcriber, format: format, feed: feed,
                        continuation: continuation, detector: detector, noSpeechTimeout: noSpeechTimeout,
                        onPartial: onPartial, onWarning: onWarning
                    )
                }
            }
        } onCancel: {
            listen.cancel()
            queue.async { if self.current === listen { self.finish(sending: false) } }
        }
    }

    /// Ends the turn with "" once it's clear nothing is being said (no words and
    /// no voice on the mic); otherwise lets the speaker finish. The voice loop
    /// calls it when a reply is ready to read out. Carries over to the next
    /// listen if none is running.
    func yieldIfSilent() {
        queue.async { self.yieldRequested = true }
    }

    private func begin(
        _ listen: Listen,
        analyzer: SpeechAnalyzer,
        transcriber: SpeechTranscriber,
        format: AVAudioFormat,
        feed: AsyncStream<AnalyzerInput>.Continuation,
        continuation: CheckedContinuation<String, Error>,
        detector: TurnDetector,
        noSpeechTimeout: TimeInterval,
        onPartial: @escaping @Sendable (String) -> Void,
        onWarning: @escaping @Sendable () -> Void
    ) {
        guard !listen.isCancelled else {
            feed.finish()
            Task { await analyzer.cancelAndFinishNow() }
            continuation.resume(returning: "")
            return
        }
        current = listen
        self.continuation = continuation
        self.analyzer = analyzer
        self.detector = detector
        self.onPartial = onPartial
        self.onWarning = onWarning
        latest = ""
        lastTextAt = nil
        warned = false
        startedAt = Date()

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    let isFinal = result.isFinal
                    self?.queue.async { self?.received(text, isFinal: isFinal, in: listen) }
                }
            } catch {
                // The analyzer stopped on its own (audio interrupted, model evicted).
                // Keep what was heard rather than throwing it away.
                self?.queue.async {
                    guard let self, self.current === listen else { return }
                    self.finish(sending: true)
                }
            }
        }

        let input = engine.inputNode
        let micFormat = input.outputFormat(forBus: 0)
        audio.start(feed: feed, from: micFormat, to: format)
        input.removeTap(onBus: 0)
        let audio = audio
        input.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { buffer, _ in
            audio.handle(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            fail(error)
            return
        }

        let ticker = DispatchSource.makeTimerSource(queue: queue)
        ticker.schedule(deadline: .now() + 0.1, repeating: 0.1)
        ticker.setEventHandler { [weak self] in self?.tick(noSpeechTimeout: noSpeechTimeout) }
        ticker.resume()
        self.ticker = ticker
    }

    /// Finalized results are kept for good; the volatile one is the rough draft
    /// of whatever comes after them, replaced as it firms up.
    private func received(_ text: String, isFinal: Bool, in listen: Listen) {
        if isFinal {
            listen.finalized = Self.join(listen.finalized, text)
            listen.volatile = ""
        } else {
            listen.volatile = text
        }
        // A turn still finalizing after it ended updates only its own transcript.
        guard listen === current, continuation != nil else { return }
        let combined = listen.transcript
        guard combined != latest else { return }
        latest = combined
        lastTextAt = Date()
        onPartial?(combined)
    }

    private func tick(noSpeechTimeout: TimeInterval) {
        guard continuation != nil else { return }
        let now = Date()
        if now.timeIntervalSince(startedAt) > Self.maximumTurn {
            finish(sending: true)
            return
        }
        let sinceSound = audio.lastVoiceAt.map { now.timeIntervalSince($0) }
        // Words can lag the mic by a moment; don't cut off someone just starting.
        if yieldRequested, latest.isEmpty, (sinceSound ?? .infinity) > 1.5 {
            finish(sending: false)
            return
        }
        guard let lastTextAt else {
            if now.timeIntervalSince(startedAt) > noSpeechTimeout { finish(sending: false) }
            return
        }
        switch detector.decide(latest, sinceText: now.timeIntervalSince(lastTextAt), sinceSound: sinceSound) {
        case .send:
            finish(sending: true)
        case .warn:
            if !warned {
                warned = true
                onWarning?()
            }
        case .listen:
            warned = false
        }
    }

    /// Stops the mic. When sending, waits for the analyzer to finalize the rest
    /// of what it heard, then returns the whole transcript.
    private func finish(sending: Bool) {
        guard let continuation, let listen = current else { return }
        self.continuation = nil
        current = nil
        yieldRequested = false
        ticker?.cancel()
        ticker = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        audio.stop()
        let analyzer = self.analyzer
        let results = resultsTask
        self.analyzer = nil
        resultsTask = nil

        guard sending else {
            results?.cancel()
            Task { await analyzer?.cancelAndFinishNow() }
            continuation.resume(returning: "")
            return
        }
        Task { [self] in
            try? await analyzer?.finalizeAndFinishThroughEndOfInput()
            await results?.value
            // `received` hops onto `queue`, so this runs after the last of them.
            queue.async {
                let text = TurnDetector.removingSendPhrase(listen.transcript)
                continuation.resume(returning: text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    private func fail(_ error: Error) {
        guard let continuation else { return }
        self.continuation = nil
        current = nil
        yieldRequested = false
        ticker?.cancel()
        ticker = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        audio.stop()
        resultsTask?.cancel()
        resultsTask = nil
        let analyzer = self.analyzer
        self.analyzer = nil
        Task { await analyzer?.cancelAndFinishNow() }
        continuation.resume(throwing: error)
    }

    private static func join(_ head: String, _ tail: String) -> String {
        let head = head.trimmingCharacters(in: .whitespaces)
        let tail = tail.trimmingCharacters(in: .whitespaces)
        if head.isEmpty { return tail }
        if tail.isEmpty { return head }
        return "\(head) \(tail)"
    }
}

/// One listen's own state. The transcript lives here, not on the listener, so
/// a turn still finalizing can't read (or be overwritten by) the next one.
nonisolated private final class Listen: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    // Guarded by the listener's queue.
    var finalized = ""
    var volatile = ""

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }

    /// Finalized text plus the rough draft of whatever comes after it.
    var transcript: String {
        [finalized, volatile].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// The mic tap's side: converts audio to the analyzer's format and feeds it,
/// and tracks voice activity against an adaptive noise floor (road noise, AC).
/// Called on the audio thread, so it's lock-protected.
nonisolated private final class AudioInput: @unchecked Sendable {
    private let lock = NSLock()
    private var feed: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var target: AVAudioFormat?
    private var _lastVoiceAt: Date?
    private var noiseFloor: Float = -50

    var lastVoiceAt: Date? { lock.withLock { _lastVoiceAt } }

    func start(feed: AsyncStream<AnalyzerInput>.Continuation, from source: AVAudioFormat, to target: AVAudioFormat) {
        lock.withLock {
            self.feed = feed
            self.target = target
            converter = source == target ? nil : AVAudioConverter(from: source, to: target)
            _lastVoiceAt = nil
            noiseFloor = -50
        }
    }

    func stop() {
        lock.withLock {
            feed?.finish()
            feed = nil
            converter = nil
        }
    }

    func handle(_ buffer: AVAudioPCMBuffer) {
        let level = Self.level(of: buffer)
        lock.withLock {
            guard let feed else { return }
            if let converted = convert(buffer) { feed.yield(AnalyzerInput(buffer: converted)) }
            // Falls fast to quiet, rises slowly, so steady noise becomes the floor
            // while speech stands out above it.
            noiseFloor = level < noiseFloor ? level : noiseFloor + (level - noiseFloor) * 0.005
            if level > noiseFloor + 12, level > -52 { _lastVoiceAt = Date() }
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter, let target else { return buffer }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return status == .error || output.frameLength == 0 ? nil : output
    }

    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return -100 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += channel[index] * channel[index] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        return 20 * log10(max(rms, 1e-6))
    }
}
