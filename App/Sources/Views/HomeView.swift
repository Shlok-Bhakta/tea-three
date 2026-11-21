import SwiftUI
import TeaThreeKit

/// Voice first: the latest exchange up top, one big talk button below with
/// photos and typing to either side. Typing stays tucked away until asked for.
/// Hidden extra: press and hold anywhere in the space above the controls to
/// talk for as long as you hold, then let go to send.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var showSettings = false
    @State private var showModels = false
    @State private var showVoices = false
    @State private var showConnection = false
    @State private var showKeyboard = false
    @State private var typed = ""
    @FocusState private var typing: Bool
    /// True while a press-and-hold is down; resets even when the system cancels the gesture.
    @GestureState private var holdPressed = false

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
                        .simultaneousGesture(holdToTalk)
                        .onChange(of: holdPressed) { _, pressed in
                            if !pressed { voice.endHold() }
                        }
                    notices
                    controls
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
            // `SIMCTL_CHILD_TEA_THREE_OPEN=models|settings|voice|connection|keyboard` for screenshots.
            .task {
                switch ProcessInfo.processInfo.environment["TEA_THREE_OPEN"] {
                case "models": showModels = true
                case "settings": showSettings = true
                case "voice": showVoices = true
                case "connection": showConnection = true
                case "keyboard": showKeyboard = true
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

    /// Long press, then hold: listens with no end-of-turn cutoff until release.
    /// Works with hands-free on or off. Deliberately undocumented in the UI.
    private var holdToTalk: some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .updating($holdPressed) { value, pressed, _ in
                if case .second(true, _) = value { pressed = true }
            }
            .onChanged { value in
                if case .second(true, _) = value, hasModel, !voice.isHolding {
                    typing = false
                    voice.beginHold()
                }
            }
            .onEnded { _ in voice.endHold() }
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
                     ? "Tap the mic and just talk. Everything goes to your “\(model.settings.threadTitle)” thread in T3 Code."
                     : "Tap the model under the mic to choose which model your Clanker runs on.")
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

    // MARK: Controls

    private var canSend: Bool { hasModel && (!typed.trimmingCharacters(in: .whitespaces).isEmpty || !model.pendingPhotos.isEmpty) }

    private var controls: some View {
        VStack(spacing: 14) {
            PendingPhotosStrip()
                .padding(.horizontal, 20)
            if showKeyboard {
                textBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            StatusLine(voice: voice, hasModel: hasModel)
                .padding(.horizontal, 24)
            HStack {
                PhotoButton(diameter: 54)
                    .disabled(!hasModel)
                    .opacity(hasModel ? 1 : 0.5)
                Spacer()
                TalkButton(voice: voice, enabled: hasModel) {
                    typing = false
                    voice.toggle()
                }
                Spacer()
                keyboardButton
            }
            .padding(.horizontal, 36)
            modelPill
        }
        .padding(.bottom, 8)
        .animation(.snappy, value: showKeyboard)
    }

    private var keyboardButton: some View {
        Button {
            showKeyboard.toggle()
            typing = showKeyboard
        } label: {
            Image(systemName: showKeyboard ? "keyboard.chevron.compact.down" : "keyboard")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(theme.foreground)
                .frame(width: 54, height: 54)
                .glassEffect(.regular.interactive(), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!hasModel)
        .opacity(hasModel ? 1 : 0.5)
        .accessibilityLabel(showKeyboard ? "Hide keyboard" : "Type instead")
    }

    /// Only shown on request: a slim field with a send arrow.
    private var textBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(voice.isWorking ? "Steer the Clanker…" : "Type a message", text: $typed, axis: .vertical)
                .lineLimit(1...5)
                .focused($typing)
                .foregroundStyle(theme.foreground)
                .padding(.vertical, 8)
                .onSubmit(sendTyped)
            Button(action: sendTyped) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(theme.primaryForeground)
                    .frame(width: 32, height: 32)
                    .background(theme.primary, in: Circle())
            }
            .disabled(!canSend)
            .opacity(canSend ? 1 : 0.4)
            .accessibilityLabel("Send")
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .glassEffect(.regular.tint(theme.composerSurface.opacity(0.35)), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 16)
    }

    private var modelPill: some View {
        Button { showModels = true } label: {
            HStack(spacing: 6) {
                if let selection = model.settings.copilotModel,
                   let provider = model.capabilities?.lookup(selection)?.provider
                {
                    ProviderBadge(provider: provider)
                    Text(ModelOptionText.summary(selection, in: model.capabilities))
                        .foregroundStyle(theme.foregroundSecondary)
                } else {
                    Image(systemName: "cpu").foregroundStyle(theme.primaryText)
                    Text(model.capabilities != nil ? "Choose model" : model.connection?.isConnected == false ? "Models load once connected" : "Loading models…")
                        .foregroundStyle(theme.primaryText)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(theme.foregroundSecondary)
            }
            .font(.footnote.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 30)
        }
        .buttonStyle(.plain)
        .disabled(model.capabilities == nil)
        .accessibilityLabel("Model and reasoning settings")
    }

    private func sendTyped() {
        guard canSend else { return }
        let text = typed
        typed = ""
        typing = false
        showKeyboard = false
        Task { await voice.sendTyped(text) }
    }
}

/// The big one: starts hands-free talk, and stops it. Pulses while listening.
private struct TalkButton: View {
    @Environment(\.theme) private var theme
    let voice: VoiceSession
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: voice.isRunning ? "stop.fill" : "mic.fill")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(theme.primaryForeground)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 88, height: 88)
                .glassEffect(.regular.tint(theme.primary.opacity(voice.isRunning ? 0.95 : 0.8)).interactive(), in: Circle())
                .background {
                    if voice.phase == .listening || voice.isHolding { PulseRing(color: theme.primary) }
                }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .sensoryFeedback(.impact, trigger: voice.isRunning)
        .accessibilityLabel(voice.isRunning ? "Stop talking" : "Talk")
    }
}

/// One line above the controls saying what's happening, plus what's being heard.
private struct StatusLine: View {
    @Environment(\.theme) private var theme
    let voice: VoiceSession
    let hasModel: Bool

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(theme.foregroundSecondary)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .frame(maxWidth: .infinity)
            .contentTransition(.opacity)
            .animation(.default, value: text)
    }

    private var text: String {
        if voice.isHolding { return "Listening until you let go…" }
        switch voice.phase {
        case .listening:
            return voice.isWorking ? "Working on it. Talk to steer, or say “cancel that”." : "Listening… just talk"
        case .thinking: return "Working on it…"
        case .speaking: return "Speaking…"
        case .idle: return hasModel ? "Tap to talk" : "Choose a model first"
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
