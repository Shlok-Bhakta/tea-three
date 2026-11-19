import AVFoundation
import SwiftUI

/// Picks the voice replies are read in. Tapping a voice previews it.
struct VoicePicker: View {
    @Environment(\.theme) private var theme
    @AppStorage(Speaker.voiceKey) private var voiceID = ""
    @AppStorage(Speaker.rateKey) private var rate = 1.0
    @State private var voices = Speaker.availableVoices()
    @State private var preview = AVSpeechSynthesizer()
    @State private var personalVoice = AVSpeechSynthesizer.personalVoiceAuthorizationStatus

    private var selectedID: String { voiceID.isEmpty ? (voices.first?.identifier ?? "") : voiceID }
    private var hasGoodVoice: Bool { voices.contains { $0.quality != .default } }

    var body: some View {
        List {
            if !hasGoodVoice {
                Section {
                    Label {
                        Text("Only basic voices are installed. Add a Premium one (Ava, Zoe, Evan, Nathan…) for free: open iOS Settings, search for “Voices”, pick English, and download one. It shows up here.")
                    } icon: {
                        Image(systemName: "arrow.down.circle.fill").foregroundStyle(theme.primaryText)
                    }
                    .font(.subheadline)
                }
            }

            Section("Speed") {
                HStack {
                    Image(systemName: "tortoise.fill").foregroundStyle(theme.foregroundSecondary)
                    Slider(value: $rate, in: 0.8...1.3, step: 0.05) { editing in
                        if !editing { play(selectedID) }
                    }
                    Image(systemName: "hare.fill").foregroundStyle(theme.foregroundSecondary)
                }
            }

            Section {
                ForEach(voices, id: \.identifier) { voice in
                    Button {
                        voiceID = voice.identifier
                        play(voice.identifier)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(voice.name).foregroundStyle(theme.foreground)
                                Text(Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language)
                                    .font(.caption)
                                    .foregroundStyle(theme.foregroundSecondary)
                            }
                            Spacer()
                            if let badge = badge(for: voice) {
                                Text(badge)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(theme.primaryText)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(theme.primary.opacity(0.16), in: Capsule())
                            }
                            if voice.identifier == selectedID {
                                Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(theme.primaryText)
                            }
                        }
                    }
                }
            } header: {
                Text("Voices on this iPhone")
            } footer: {
                Text("Premium and Enhanced voices sound far more natural. More can be downloaded in iOS Settings › Accessibility (search “Voices”).")
            }

            if personalVoice == .notDetermined {
                Section {
                    Button("Use my Personal Voice", systemImage: "person.wave.2") {
                        AVSpeechSynthesizer.requestPersonalVoiceAuthorization { status in
                            Task { @MainActor in
                                personalVoice = status
                                voices = Speaker.availableVoices()
                            }
                        }
                    }
                } footer: {
                    Text("If you've made a Personal Voice in iOS Settings, Tea Three can reply in it.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThemeBackground())
        .navigationTitle("Voice")
        .onDisappear { preview.stopSpeaking(at: .immediate) }
    }

    private func badge(for voice: AVSpeechSynthesisVoice) -> String? {
        if voice.voiceTraits.contains(.isPersonalVoice) { return "Personal" }
        switch voice.quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return nil
        }
    }

    private func play(_ id: String) {
        preview.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: "Got it. I sent that to your Health thread, and the build on crabcake is still running.")
        utterance.voice = AVSpeechSynthesisVoice(identifier: id)
        utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(rate))
        preview.speak(utterance)
    }
}
