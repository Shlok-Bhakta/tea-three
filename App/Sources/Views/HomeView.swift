import SwiftUI
import TeaThreeKit

/// One screen: the latest exchange, a voice orb, and a T3-style glass composer.
/// Tap the orb (or press the Action button) and just talk.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var showSettings = false
    @State private var showModels = false
    @State private var typed = ""
    @FocusState private var typing: Bool

    private var voice: VoiceSession { model.voice }
    private var hasModel: Bool { model.settings.copilotModel != nil }

    var body: some View {
        NavigationStack {
            ZStack {
                ThemeBackground()
                VStack(spacing: 0) {
                    exchange
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    VoiceOrb(voice: voice, enabled: hasModel)
                        .padding(.bottom, 18)
                    notices
                    composer
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Image("Mark").resizable().scaledToFit().frame(height: 18).foregroundStyle(theme.primaryText)
                        Text("Tea Three").font(.headline).foregroundStyle(theme.foreground)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            #if DEBUG
            // `SIMCTL_CHILD_TEA_THREE_OPEN=models|settings` for screenshots.
            .task {
                switch ProcessInfo.processInfo.environment["TEA_THREE_OPEN"] {
                case "models": showModels = true
                case "settings": showSettings = true
                default: break
                }
            }
            #endif
            .sheet(isPresented: $showSettings) { SettingsView().themed() }
            .sheet(isPresented: $showModels) {
                ModelSheet().themed().presentationDetents([.medium, .large])
            }
        }
    }

    // MARK: Latest exchange

    /// Only the latest exchange. The full history lives in the thread in T3 Code.
    @ViewBuilder
    private var exchange: some View {
        let said = voice.partial.isEmpty ? voice.turns.last { $0.role == .you }?.text : voice.partial
        let reply = voice.turns.last.flatMap { $0.role == .you ? nil : $0.text }
        if said == nil, reply == nil {
            VStack(spacing: 14) {
                Image("Mark").resizable().scaledToFit().frame(height: 56).foregroundStyle(theme.primaryText)
                Text(hasModel ? "What should we do?" : "Pick a model to start")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(theme.foreground)
                Text("Everything goes to your pinned “\(model.settings.threadTitle)” thread in T3 Code, which sends it to the right place.")
                    .font(.subheadline)
                    .foregroundStyle(theme.foregroundSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let said {
                        Text(said)
                            .foregroundStyle(theme.userBubbleForeground)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(theme.userBubble, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .opacity(voice.partial.isEmpty ? 1 : 0.6)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.leading, 48)
                    }
                    if let reply {
                        Text(reply)
                            .foregroundStyle(theme.foreground)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.trailing, 24)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
            }
            .defaultScrollAnchor(.bottom)
        }
    }

    @ViewBuilder
    private var notices: some View {
        if let error = model.lastError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(theme.primaryText)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
        }
        if model.outboxCount > 0 {
            Label("\(model.outboxCount) waiting to send", systemImage: "tray.and.arrow.up")
                .font(.footnote)
                .foregroundStyle(theme.foregroundSecondary)
                .padding(.bottom, 8)
        }
    }

    // MARK: Composer

    private var canSend: Bool { hasModel && (!typed.trimmingCharacters(in: .whitespaces).isEmpty || !model.pendingPhotos.isEmpty) }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            PendingPhotosStrip()
            TextField("Message your Copilot", text: $typed, axis: .vertical)
                .lineLimit(1...5)
                .focused($typing)
                .foregroundStyle(theme.foreground)
                .padding(.horizontal, 4)
                .onSubmit(sendTyped)
            HStack(spacing: 8) {
                PhotoButton()
                    .disabled(!hasModel)
                modelPill
                Spacer(minLength: 0)
                sendButton
            }
        }
        .padding(14)
        .glassEffect(.regular.tint(theme.composerSurface.opacity(0.35)), in: RoundedRectangle(cornerRadius: 27, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private var sendButton: some View {
        let icon = canSend ? "arrow.up" : (voice.isRunning ? "stop.fill" : "waveform")
        return Button {
            if canSend { sendTyped() } else { voice.toggle() }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(theme.primaryForeground)
                .frame(width: 36, height: 36)
                .background(theme.primary, in: Circle())
        }
        .disabled(!hasModel)
        .opacity(hasModel ? 1 : 0.4)
        .accessibilityLabel(canSend ? "Send" : (voice.isRunning ? "Stop listening" : "Start talking"))
    }

    private var modelPill: some View {
        Button { showModels = true } label: {
            HStack(spacing: 6) {
                if let selection = model.settings.copilotModel,
                   let provider = model.capabilities?.lookup(selection)?.provider
                {
                    ProviderBadge(provider: provider)
                    Text(ModelOptionText.summary(selection, in: model.capabilities))
                        .foregroundStyle(theme.foreground)
                } else {
                    Image(systemName: "cpu").foregroundStyle(theme.primaryText)
                    Text(model.capabilities == nil ? "Loading models…" : "Choose model")
                        .foregroundStyle(theme.primaryText)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(theme.foregroundSecondary)
            }
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(theme.foreground.opacity(0.07), in: Capsule())
        }
        .disabled(model.capabilities == nil)
        .accessibilityLabel("Model and reasoning settings")
    }

    private func sendTyped() {
        guard canSend else { return }
        let text = typed
        typed = ""
        typing = false
        Task { await voice.sendTyped(text) }
    }
}

/// The hands-free button: a tinted glass orb that pulses while listening.
private struct VoiceOrb: View {
    @Environment(\.theme) private var theme
    let voice: VoiceSession
    let enabled: Bool
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 10) {
            Button { voice.toggle() } label: {
                ZStack {
                    if voice.phase == .listening {
                        Circle()
                            .stroke(theme.primary.opacity(0.5), lineWidth: 2)
                            .frame(width: 104, height: 104)
                            .scaleEffect(pulse ? 1.35 : 1)
                            .opacity(pulse ? 0 : 1)
                            .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: pulse)
                            .onAppear { pulse = true }
                            .onDisappear { pulse = false }
                    }
                    Image(systemName: icon)
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(voice.isRunning ? theme.primaryForeground : theme.primaryText)
                        .symbolEffect(.variableColor.iterative, isActive: voice.phase == .listening || voice.phase == .thinking)
                        .frame(width: 92, height: 92)
                        .glassEffect(
                            .regular.tint(voice.isRunning ? theme.primary : theme.primary.opacity(0.18)).interactive(),
                            in: Circle()
                        )
                }
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.5)
            .accessibilityLabel(voice.isRunning ? "Stop listening" : "Start talking")
            .sensoryFeedback(.impact, trigger: voice.isRunning)

            Text(status)
                .font(.footnote.weight(.medium))
                .foregroundStyle(theme.foregroundSecondary)
        }
    }

    private var icon: String {
        switch voice.phase {
        case .idle: "mic.fill"
        case .listening: "waveform"
        case .thinking: "ellipsis"
        case .speaking: "speaker.wave.2.fill"
        }
    }

    private var status: String {
        switch voice.phase {
        case .idle: enabled ? "Tap to talk" : "Choose a model first"
        case .listening: "Listening…"
        case .thinking: "Working on it…"
        case .speaking: "Speaking"
        }
    }
}
