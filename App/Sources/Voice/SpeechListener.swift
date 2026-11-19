import AVFoundation
@preconcurrency import Speech

/// One utterance of on-device speech-to-text, ended by a pause.
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

    private let recognizer = SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "tea-three.speech")

    // Guarded by `queue`.
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var continuation: CheckedContinuation<String, Error>?
    private var latest = ""
    private var silenceTimer: DispatchWorkItem?

    static func requestAuthorization() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        let microphone = await AVAudioApplication.requestRecordPermission()
        return speech && microphone
    }

    /// Returns what was said once `silence` seconds pass after the last word.
    /// Returns "" if nothing is said within `noSpeechTimeout`.
    func listen(
        silence: TimeInterval,
        noSpeechTimeout: TimeInterval = 12,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { throw Failure.notAuthorized }
        guard let recognizer, recognizer.isAvailable else { throw Failure.unavailable }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    self.begin(recognizer: recognizer, continuation: continuation, silence: silence, noSpeechTimeout: noSpeechTimeout, onPartial: onPartial)
                }
            }
        } onCancel: {
            queue.async { self.finish(with: .success("")) }
        }
    }

    private func begin(
        recognizer: SFSpeechRecognizer,
        continuation: CheckedContinuation<String, Error>,
        silence: TimeInterval,
        noSpeechTimeout: TimeInterval,
        onPartial: @escaping @Sendable (String) -> Void
    ) {
        self.continuation = continuation
        latest = ""

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition {
            // Private, works offline, and has no one-minute server cap.
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            finish(with: .failure(error))
            return
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            self.queue.async {
                if let text {
                    if text != self.latest {
                        self.latest = text
                        onPartial(text)
                        self.scheduleTimer(after: silence)
                    }
                    if isFinal { self.finish(with: .success(self.latest)) }
                } else if failed {
                    // "No speech detected" and cancellations land here too.
                    self.finish(with: .success(self.latest))
                }
            }
        }
        scheduleTimer(after: noSpeechTimeout)
    }

    private func scheduleTimer(after interval: TimeInterval) {
        silenceTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.finish(with: .success(self.latest))
        }
        silenceTimer = timer
        queue.asyncAfter(deadline: .now() + interval, execute: timer)
    }

    private func finish(with result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        silenceTimer?.cancel()
        silenceTimer = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        continuation.resume(with: result.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
    }
}
