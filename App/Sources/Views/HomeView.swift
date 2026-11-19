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
                ModelMenu()
                    .padding()
                Spacer()
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

            lastExchange

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
            .disabled(model.settings.copilotModel == nil)
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
                    .disabled(typed.isEmpty || model.settings.copilotModel == nil)
            }
        }
        .padding()
    }

    /// Only the latest exchange. The full history lives in the thread in T3 Code.
    @ViewBuilder
    private var lastExchange: some View {
        let said = voice.partial.isEmpty ? voice.turns.last { $0.role == .you }?.text : voice.partial
        let reply = voice.turns.last.flatMap { $0.role == .you ? nil : $0.text }
        VStack(spacing: 6) {
            if let said {
                Text(said).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            if let reply {
                Text(reply).font(.body).lineLimit(6)
            }
            if said == nil, reply == nil {
                Text("Everything goes to your pinned “\(model.settings.threadTitle)” thread in T3 Code, which sends it to the right place.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
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
        case .idle: model.settings.copilotModel == nil ? "Pick a model to start" : "Tap to talk"
        case .listening: "Listening…"
        case .thinking: "Working on it…"
        case .speaking: "Speaking"
        }
    }
}

/// The model every conversation starts with. The Copilot uses it, and threads
/// it starts inherit it. The list comes from the server's `orchestrator_capabilities`.
private struct ModelMenu: View {
    @Environment(AppModel.self) private var model

    private var providers: [OrchestratorCapabilities.Provider] {
        model.capabilities?.providers.filter { !$0.models.isEmpty } ?? []
    }

    private var currentName: String? {
        guard let selection = model.settings.copilotModel else { return nil }
        let provider = providers.first { $0.providerInstanceId == (selection.instanceId ?? selection.provider) }
        let name = provider?.models.first { $0.id == selection.model }?.displayName ?? selection.model
        return provider.map { "\(name) · \($0.displayName ?? $0.providerInstanceId)" } ?? name
    }

    var body: some View {
        Menu {
            ForEach(providers) { provider in
                Section(provider.displayName ?? provider.providerInstanceId) {
                    ForEach(provider.models) { option in
                        let selection = ModelSelection(instanceId: provider.providerInstanceId, model: option.id)
                        Button {
                            model.choose(model: selection)
                        } label: {
                            if selection == model.settings.copilotModel {
                                Label(option.displayName, systemImage: "checkmark")
                            } else {
                                Text(option.displayName)
                            }
                        }
                    }
                }
            }
        } label: {
            HStack {
                Image(systemName: "cpu")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Model").font(.caption).foregroundStyle(.secondary)
                    Text(currentName ?? (providers.isEmpty ? "Loading models…" : "Pick a model"))
                        .foregroundStyle(currentName == nil ? Color.orange : Color.primary)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down").foregroundStyle(.secondary)
            }
            .padding()
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
        }
        .disabled(providers.isEmpty)
    }
}
