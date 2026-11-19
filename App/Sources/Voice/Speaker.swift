import AVFoundation

/// Text-to-speech in Tea Three's own voice (not Siri's).
final class Speaker: NSObject {
    private let synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Never>?
    private lazy var voice: AVSpeechSynthesisVoice? = Self.bestVoice()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) async {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        utterance.postUtteranceDelay = 0.1
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        finish()
    }

    private func finish() {
        continuation?.resume()
        continuation = nil
    }

    /// The nicest installed voice for the user's language: premium, then enhanced.
    private static func bestVoice() -> AVSpeechSynthesisVoice? {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == language }
        return voices.first { $0.quality == .premium }
            ?? voices.first { $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: language)
    }
}

extension Speaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finish() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finish() }
    }
}

enum AudioSession {
    /// Mic + speaker, ducking navigation or music instead of killing it.
    static func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP, .duckOthers])
        try session.setActive(true)
    }

    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

enum Earcon {
    // Built-in "begin/end recording" tones, the same ones dictation uses.
    static func listening() { AudioServicesPlaySystemSound(1113) }
    static func heard() { AudioServicesPlaySystemSound(1114) }
}
