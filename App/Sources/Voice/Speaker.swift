import AVFoundation
import UIKit

/// Text-to-speech in Tea Three's own voice (not Siri's). The voice and rate
/// come from Settings; with nothing picked, the best installed English voice.
final class Speaker: NSObject {
    static let voiceKey = "voice.identifier"
    static let rateKey = "voice.rate"

    private let synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    private lazy var natural = NaturalVoicePlayer()

    /// The selected voice's identifier: a natural voice ("pocket:george") or an
    /// iPhone voice. Natural voices are the default once downloaded.
    static var selectedIdentifier: String {
        if let id = UserDefaults.standard.string(forKey: voiceKey), !id.isEmpty,
           NaturalVoice.voice(forIdentifier: id) == nil || NaturalVoice.isAvailable
        {
            return id
        }
        if NaturalVoice.isAvailable { return NaturalVoice.identifierPrefix + NaturalVoice.voices[0].id }
        return availableVoices().first?.identifier ?? ""
    }

    static var selectedName: String {
        let id = selectedIdentifier
        return NaturalVoice.voice(forIdentifier: id)?.name ?? AVSpeechSynthesisVoice(identifier: id)?.name ?? "Default"
    }

    func speak(_ text: String) async {
        stop()
        let rate = UserDefaults.standard.object(forKey: Self.rateKey) as? Double ?? 1.0
        if let voice = NaturalVoice.voice(forIdentifier: Self.selectedIdentifier) {
            do {
                try await natural.speak(Self.speakable(text), voice: voice.id, rate: rate)
                return
            } catch is CancellationError {
                return
            } catch {
                // Fall through to an iPhone voice rather than staying silent.
            }
        }
        let utterance = AVSpeechUtterance(string: Self.speakable(text))
        utterance.voice = Self.chosenVoice()
        utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(rate))
        utterance.prefersAssistiveTechnologySettings = false
        utterance.postUtteranceDelay = 0.1
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        natural.stop()
        finish()
    }

    private func finish() {
        continuation?.resume()
        continuation = nil
    }

    /// The iPhone voice to use: the selected one, or the best installed.
    static func chosenVoice() -> AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice(identifier: selectedIdentifier) ?? availableVoices().first
    }

    /// English voices, best first: premium, then enhanced, then the rest; the
    /// phone's own accent before other accents.
    static func availableVoices() -> [AVSpeechSynthesisVoice] {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let family = String(language.prefix(2))
        func rank(_ voice: AVSpeechSynthesisVoice) -> (Int, Int, String) {
            let quality = switch voice.quality {
            case .premium: 0
            case .enhanced: 1
            default: voice.voiceTraits.contains(.isPersonalVoice) ? 0 : 2
            }
            return (quality, voice.language == language ? 0 : 1, voice.name)
        }
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(family) && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sorted { rank($0) < rank($1) }
    }

    /// Strips what reads badly aloud: markdown, code fences, raw links.
    static func speakable(_ text: String) -> String {
        var text = text
        text = text.replacingOccurrences(of: "```[\\s\\S]*?```", with: " (code omitted) ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]+\\)", with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "https?://\\S+", with: "a link", options: .regularExpression)
        text = text.replacingOccurrences(of: "[*_`#>|]+", with: "", options: .regularExpression)
        return text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
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
    /// A quiet tick plus a soft haptic, a second before a turn is sent.
    static func aboutToSend() {
        AudioServicesPlaySystemSound(1104)
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }
}
