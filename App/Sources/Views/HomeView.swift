import SwiftUI
import TeaThreeKit

/// One big button. Tap it (or press the Action button) and just talk.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var showSettings = false
    @State private var typed = ""
    @FocusState private var typing: Bool

    private var voice: VoiceSession { model.voice }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                transcript
                Divider()
                controls
            }
            .navigationTitle("Tea Three")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if voice.turns.isEmpty {
                        ContentUnavailableView(
                            "Just talk",
                            systemImage: "waveform",
                            description: Text("Everything goes to your pinned “\(model.settings.threadTitle)” thread in T3 Code, which routes it to the right place. Say “goodbye” to stop listening.")
                        )
                        .padding(.top, 40)
                    }
                    ForEach(voice.turns) { turn in
                        TurnRow(turn: turn).id(turn.id)
                    }
                    if !voice.partial.isEmpty {
                        TurnRow(turn: .init(role: .you, text: voice.partial)).opacity(0.5).id("partial")
                    }
                }
                .padding()
            }
            .onChange(of: voice.turns.count) {
                withAnimation { proxy.scrollTo(voice.turns.last?.id, anchor: .bottom) }
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 14) {
            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if model.outboxCount > 0 {
                Label("\(model.outboxCount) waiting to send", systemImage: "tray.and.arrow.up")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button { voice.toggle() } label: {
                ZStack {
                    Circle()
                        .fill(voice.isRunning ? Color.orange : Color.accentColor)
                        .frame(width: 112, height: 112)
                        .shadow(radius: voice.phase == .listening ? 16 : 4)
                    Image(systemName: icon)
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(.white)
                        .symbolEffect(.variableColor.iterative, isActive: voice.phase == .listening || voice.phase == .thinking)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(voice.isRunning ? "Stop listening" : "Start talking")
            .sensoryFeedback(.impact, trigger: voice.isRunning)

            Text(status).font(.callout).foregroundStyle(.secondary)

            HStack {
                TextField("Or type…", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .focused($typing)
                    .submitLabel(.send)
                    .onSubmit(sendTyped)
                Button("Send", systemImage: "arrow.up.circle.fill", action: sendTyped)
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .disabled(typed.isEmpty)
            }
        }
        .padding()
    }

    private func sendTyped() {
        let text = typed
        typed = ""
        Task { await voice.sendTyped(text) }
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
        case .idle: "Tap to talk"
        case .listening: "Listening…"
        case .thinking: "Working on it…"
        case .speaking: "Speaking"
        }
    }
}

private struct TurnRow: View {
    let turn: VoiceSession.Turn

    var body: some View {
        switch turn.role {
        case .you:
            HStack {
                Spacer(minLength: 40)
                Text(turn.text)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
            }
        case .copilot:
            HStack {
                Text(turn.text)
                    .padding(10)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                Spacer(minLength: 40)
            }
        case .status:
            Text(turn.text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
    }
}
