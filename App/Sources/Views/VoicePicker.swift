import AVFoundation
import SwiftUI

/// Picks the voice replies are read in. Tapping a voice previews it.
struct VoicePicker: View {
    /// From the observable download, so the list appears the moment it finishes.
    private var naturalReady: Bool { VoiceDownload.shared.state == .ready }
    @Environment(\.theme) private var theme
    @AppStorage(Speaker.voiceKey) private var voiceID = ""
    @AppStorage(Speaker.rateKey) private var rate = 1.0
    @State private var voices = Speaker.availableVoices()
    @State private var preview = Speaker()
    @State private var personalVoice = AVSpeechSynthesizer.personalVoiceAuthorizationStatus

    private var selectedID: String { voiceID.isEmpty ? Speaker.selectedIdentifier : voiceID }
    private var hasGoodVoice: Bool { voices.contains { $0.quality != .default } }

    var body: some View {
        List {
            if !naturalReady {
                Section {
                    VoiceDownloadRow()
                } footer: {
                    Text("Downloaded once and kept on your iPhone, so app updates stay small.")
                }
            }
            if naturalReady {
                Section {
                    ForEach(NaturalVoice.voices) { voice in
                        let id = NaturalVoice.identifierPrefix + voice.id
                        Button {
                            voiceID = id
                            play(id)
                        } label: {
                            VoiceRow(name: voice.name, detail: voice.kind, badge: "Natural", selected: id == selectedID)
                        }
                    }
                } header: {
                    Text("Natural voices")
                } footer: {
                    Text("Generated on your iPhone by Kyutai's Pocket TTS, as used in MB Books. Nothing leaves the phone.")
                }
            }

            if !naturalReady && !hasGoodVoice {
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
                        VoiceRow(
                            name: voice.name,
                            detail: Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language,
                            badge: badge(for: voice),
                            selected: voice.identifier == selectedID
                        )
                    }
                }
            } header: {
                Text("iPhone voices")
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
                    Text("If you've made a Personal Voice in iOS Settings, Clanker can reply in it.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThemeBackground())
        .navigationTitle("Voice")
        .onDisappear { preview.stop() }
    }

    private func badge(for voice: AVSpeechSynthesisVoice) -> String? {
        if voice.voiceTraits.contains(.isPersonalVoice) { return "Personal" }
        switch voice.quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return nil
        }
    }

    /// Plays a sample in the voice just picked (it's already saved as the choice).
    private func play(_ id: String) {
        Task { await preview.speak("Got it. I logged that in your food thread, and the build on crabcake is still running.") }
    }
}

private struct VoiceRow: View {
    @Environment(\.theme) private var theme
    let name: String
    let detail: String
    let badge: String?
    let selected: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).foregroundStyle(theme.foreground)
                Text(detail).font(.caption).foregroundStyle(theme.foregroundSecondary)
            }
            Spacer()
            if let badge {
                Text(badge)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(theme.primaryText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(theme.primary.opacity(0.16), in: Capsule())
            }
            if selected {
                Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(theme.primaryText)
            }
        }
    }
}

/// The one-time natural voice download: a button, then progress, then done.
struct VoiceDownloadRow: View {
    @Environment(\.theme) private var theme
    private var download: VoiceDownload { .shared }

    var body: some View {
        switch download.state {
        case .ready:
            LabeledContent("Natural voices") {
                Menu("Downloaded") {
                    Button("Remove (\(size))", role: .destructive) { download.remove() }
                }
            }
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Downloading natural voices…")
                    Spacer()
                    Button("Cancel") { download.cancel() }
                        .buttonStyle(.borderless)
                }
                ProgressView(value: fraction)
                    .tint(theme.primary)
                Text("\(Int(fraction * 100))% of \(size). Keep Clanker open.")
                    .font(.caption)
                    .foregroundStyle(theme.foregroundSecondary)
            }
        case .missing, .failed:
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    download.start()
                } label: {
                    Label("Download natural voices (\(size))", systemImage: "arrow.down.circle")
                }
                if case .failed(let message) = download.state {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var size: String {
        ByteCountFormatter.string(fromByteCount: VoiceDownload.totalBytes, countStyle: .file)
    }
}
