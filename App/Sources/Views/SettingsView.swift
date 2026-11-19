import SwiftUI
import TeaThreeKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var checking = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section("Copilot thread") {
                    TextField("Pinned thread title", text: $model.settings.threadTitle)
                    Picker("Lives in", selection: $model.settings.projectId) {
                        Text("Scratch folder").tag(String?.none)
                        ForEach(model.projects) { project in
                            Text(project.displayName).tag(Optional(project.projectId))
                        }
                    }
                    ModelPicker(title: "Copilot model", selection: $model.settings.copilotModel, capabilities: model.capabilities, noneLabel: "Automatic")
                    if let id = model.copilotThreadID {
                        LabeledContent("Thread", value: id).font(.caption).lineLimit(1).truncationMode(.middle)
                        Button("Start a fresh Copilot thread", role: .destructive) { model.resetCopilotThread() }
                    }
                }

                Section {
                    ModelPicker(title: "New threads use", selection: $model.settings.workerModel, capabilities: model.capabilities, noneLabel: "Copilot decides")
                    Picker("New threads run", selection: $model.settings.runtimeMode) {
                        Text("Server default").tag(RuntimeMode?.none)
                        ForEach(RuntimeMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(Optional(mode))
                        }
                    }
                } header: {
                    Text("Threads the Copilot starts")
                } footer: {
                    Text("Model and permission changes reach the Copilot the next time its thread is created. Use “Start a fresh Copilot thread” to apply them now.")
                }

                Section {
                    TextEditor(text: $model.settings.extraInstructions)
                        .frame(minHeight: 100)
                } header: {
                    Text("Notes for the Copilot")
                } footer: {
                    Text("For example: “Food logs go to the Health project using the food-log skill. Snooze anything I say to do later until tomorrow 9am.”")
                }

                Section("Voice") {
                    Toggle("Speak replies", isOn: $model.settings.speakReplies)
                    LabeledContent("Pause to send") {
                        Stepper(String(format: "%.1f s", model.settings.endOfSpeechSilence), value: $model.settings.endOfSpeechSilence, in: 0.8...4, step: 0.2)
                    }
                }

                Section("Server") {
                    if let credential = model.credential {
                        LabeledContent("Paired with", value: credential.environmentLabel ?? credential.serverURL.host() ?? "")
                        LabeledContent("Address", value: credential.serverURL.absoluteString)
                        if let expires = credential.expiresAt {
                            LabeledContent("Token expires", value: expires.formatted(date: .abbreviated, time: .omitted))
                        }
                    }
                    if let report = model.contractReport {
                        Text(report).font(.footnote).foregroundStyle(report.hasSuffix("compatible") ? Color.secondary : Color.orange)
                    }
                    Button {
                        Task {
                            checking = true
                            await model.refresh()
                            checking = false
                        }
                    } label: {
                        HStack { Text("Check compatibility"); Spacer(); if checking { ProgressView() } }
                    }
                    Button("Unpair", role: .destructive) {
                        model.unpair()
                        dismiss()
                    }
                }

                Section("Siri, Shortcuts & Action button") {
                    Text("“Hey Siri, tell Tea Three” sends and forgets. “Talk to Tea Three” opens hands-free mode. Assign “Talk to T3” to the Action button in Settings › Action Button › Shortcut.")
                        .font(.footnote)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

private struct ModelPicker: View {
    let title: String
    @Binding var selection: ModelSelection?
    let capabilities: OrchestratorCapabilities?
    let noneLabel: String

    var body: some View {
        Picker(title, selection: $selection) {
            Text(noneLabel).tag(ModelSelection?.none)
            ForEach(capabilities?.providers.filter { !$0.models.isEmpty } ?? []) { provider in
                Section(provider.displayName ?? provider.providerInstanceId) {
                    ForEach(provider.models) { model in
                        Text(model.displayName)
                            .tag(Optional(ModelSelection(instanceId: provider.providerInstanceId, model: model.id)))
                    }
                }
            }
        }
    }
}
