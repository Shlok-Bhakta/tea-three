import SwiftUI
import TeaThreeKit

/// One screen: the latest exchange and a T3-style glass composer. The
/// waveform button in the composer starts hands-free talk; the title shows
/// whether the server can be reached.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var showSettings = false
    @State private var showModels = false
    @State private var showVoices = false
    @State private var showConnection = false
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
                        .contentShape(Rectangle())
                        .onTapGesture { typing = false }
                    notices
                    composer
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Button { showConnection = true } label: {
                        VStack(spacing: 1) {
                            HStack(spacing: 6) {
                                Image("Mark").resizable().scaledToFit().frame(height: 15).foregroundStyle(theme.primaryText)
                                Text("Tea Three").font(.headline).foregroundStyle(theme.foreground)
                            }
                            ConnectionBadge()
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Connection to \(model.serverName)")
                    .popover(isPresented: $showConnection) {
                        ConnectionDetails().themed().presentationCompactAdaptation(.popover)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            #if DEBUG
            // `SIMCTL_CHILD_TEA_THREE_OPEN=models|settings|voice|connection` for screenshots.
            .task {
                switch ProcessInfo.processInfo.environment["TEA_THREE_OPEN"] {
                case "models": showModels = true
                case "settings": showSettings = true
                case "voice": showVoices = true
                case "connection": showConnection = true
                default: break
                }
                if let text = ProcessInfo.processInfo.environment["TEA_THREE_SAY"] {
                    let started = Date()
                    let samples = try? await NaturalVoiceEngine.shared.synthesize(text, voice: "george")
                    print("TEA_THREE_SAY natural=\(NaturalVoice.isAvailable) samples=\(samples?.count ?? -1) in \(Date().timeIntervalSince(started))s")
                    await Speaker().speak(text)
                }
            }
            #endif
            .sheet(isPresented: $showSettings) { SettingsView().themed() }
            .sheet(isPresented: $showVoices) { NavigationStack { VoicePicker() }.themed() }
            .sheet(isPresented: $showModels) {
                ModelSheet().themed().presentationDetents([.medium, .large])
            }
        }
    }

    // MARK: Latest exchange

    /// Only the latest exchange (your request, any steers, the reply). The full
    /// history lives in the thread in T3 Code.
    @ViewBuilder
    private var exchange: some View {
        let recent = Array(voice.turns.suffix(6))
        if recent.isEmpty, voice.partial.isEmpty {
            VStack(spacing: 14) {
                Image("Mark").resizable().scaledToFit().frame(height: 56).foregroundStyle(theme.primaryText)
                Text(hasModel ? "What should we do?" : "Pick a model to start")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(theme.foreground)
                Text(hasModel
                     ? "Type below, or tap \(Image(systemName: "waveform")) to talk hands-free. Everything goes to your “\(model.settings.threadTitle)” thread in T3 Code."
                     : "Tap the model button below to choose which model your Copilot runs on.")
                    .font(.subheadline)
                    .foregroundStyle(theme.foregroundSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(recent) { turn in
                        TurnView(turn: turn, server: model.serverName)
                    }
                    if !voice.partial.isEmpty {
                        Bubble(text: voice.partial).opacity(0.6)
                    }
                    if voice.isWorking {
                        HStack(spacing: 10) {
                            Label("Working on it…", systemImage: "ellipsis")
                                .symbolEffect(.variableColor.iterative)
                            Spacer(minLength: 0)
                            Button("Stop", systemImage: "stop.fill") { Task { await voice.interrupt() } }
                                .font(.subheadline.weight(.semibold))
                                .buttonStyle(.glass)
                                .tint(theme.primaryText)
                        }
                        .font(.subheadline)
                        .foregroundStyle(theme.foregroundSecondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .animation(.default, value: voice.turns)
            }
            .defaultScrollAnchor(.bottom)
        }
    }

    @ViewBuilder
    private var notices: some View {
        VStack(spacing: 8) {
            if case .unreachable = model.connection {
                Button { showConnection = true } label: {
                    Label("Can't reach \(model.serverName). Messages will wait and send once you're connected.", systemImage: "wifi.exclamationmark")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(theme.foreground)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .glassEffect(.regular.tint(Color.orange.opacity(0.25)), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
            }
            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(theme.primaryText)
                    .padding(.horizontal, 20)
            }
            if model.outboxCount > 0 {
                Label("\(model.outboxCount) waiting to send", systemImage: "tray.and.arrow.up")
                    .font(.footnote)
                    .foregroundStyle(theme.foregroundSecondary)
            }
        }
        .padding(.bottom, 8)
        .animation(.default, value: model.connection)
    }

    // MARK: Composer

    private var canSend: Bool { hasModel && (!typed.trimmingCharacters(in: .whitespaces).isEmpty || !model.pendingPhotos.isEmpty) }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            PendingPhotosStrip()
            if voice.isRunning {
                LiveLine(voice: voice)
            } else {
                TextField(voice.isWorking ? "Steer the Copilot…" : "Message your Copilot", text: $typed, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($typing)
                    .foregroundStyle(theme.foreground)
                    .padding(.horizontal, 4)
                    .onSubmit(sendTyped)
            }
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

    /// Arrow when there's something typed; otherwise starts or stops hands-free talk.
    private var sendButton: some View {
        let icon = canSend ? "arrow.up" : (voice.isRunning ? "stop.fill" : "waveform")
        return Button {
            if canSend { sendTyped() } else { typing = false; voice.toggle() }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(theme.primaryForeground)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 36, height: 36)
                .background(theme.primary, in: Circle())
                .background {
                    if voice.phase == .listening { PulseRing(color: theme.primary) }
                }
        }
        .disabled(!hasModel)
        .opacity(hasModel ? 1 : 0.4)
        .sensoryFeedback(.impact, trigger: voice.isRunning)
        .accessibilityLabel(canSend ? "Send" : (voice.isRunning ? "Stop listening" : "Talk hands-free"))
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
                    Text(model.capabilities != nil ? "Choose model" : model.connection?.isConnected == false ? "Models load once connected" : "Loading models…")
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

/// Takes the text field's place while talking hands-free: what's being heard,
/// or what the Copilot is doing.
private struct LiveLine: View {
    @Environment(\.theme) private var theme
    let voice: VoiceSession

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(theme.primaryText)
                .symbolEffect(.variableColor.iterative, isActive: voice.phase == .listening || voice.phase == .thinking)
            Text(voice.partial.isEmpty ? (voice.isWorking && voice.phase == .listening ? "Working on it. Talk to steer, or say “cancel that”." : status) : voice.partial)
                .foregroundStyle(voice.partial.isEmpty ? theme.foregroundSecondary : theme.foreground)
                .lineLimit(1...5)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 4)
        .animation(.default, value: voice.phase)
    }

    private var icon: String {
        switch voice.phase {
        case .idle, .listening: "waveform"
        case .thinking: "ellipsis"
        case .speaking: "speaker.wave.2.fill"
        }
    }

    private var status: String {
        switch voice.phase {
        case .idle, .listening: "Listening… just talk"
        case .thinking: "Working on it…"
        case .speaking: "Speaking…"
        }
    }
}

/// A ring that keeps expanding out of the talk button while it listens.
private struct PulseRing: View {
    let color: Color
    @State private var expanded = false

    var body: some View {
        Circle()
            .stroke(color.opacity(0.6), lineWidth: 2)
            .scaleEffect(expanded ? 1.6 : 1)
            .opacity(expanded ? 0 : 1)
            .onAppear {
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { expanded = true }
            }
    }
}

/// One line of the exchange: your message as a bubble with its delivery
/// status, the Copilot's reply as plain text, or a status note.
private struct TurnView: View {
    @Environment(\.theme) private var theme
    let turn: VoiceSession.Turn
    let server: String

    var body: some View {
        switch turn.role {
        case .you:
            VStack(alignment: .trailing, spacing: 5) {
                Bubble(text: turn.text)
                if let delivery = turn.delivery {
                    DeliveryLabel(delivery: delivery, server: server)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .copilot:
            Text(turn.text)
                .foregroundStyle(theme.foreground)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 24)
        case .status:
            Label(turn.text, systemImage: "info.circle")
                .font(.subheadline)
                .foregroundStyle(theme.foregroundSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct Bubble: View {
    @Environment(\.theme) private var theme
    let text: String

    var body: some View {
        Text(text)
            .foregroundStyle(theme.userBubbleForeground)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(theme.userBubble, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 48)
    }
}

/// "Sending…", "Delivered to crabcake", "Waiting for connection", or "Not sent".
private struct DeliveryLabel: View {
    @Environment(\.theme) private var theme
    let delivery: VoiceSession.Turn.Delivery
    let server: String

    var body: some View {
        Group {
            switch delivery {
            case .sending:
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("Sending…")
                }
            case .delivered:
                Label("Delivered to \(server)", systemImage: "checkmark")
            case .steered:
                Label("Steered", systemImage: "arrow.turn.down.right")
            case .queued:
                Label("Waiting for connection", systemImage: "clock")
            case .failed:
                Label("Not sent", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .foregroundStyle(theme.foregroundSecondary)
        .padding(.trailing, 6)
        .animation(.default, value: delivery)
    }
}
