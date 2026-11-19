import SwiftUI
import TeaThreeKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("theme") private var themeName = ThemeName.t3Chat.rawValue
    @Environment(\.dismiss) private var dismiss
    @State private var checking = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    Picker("Theme", selection: $themeName) {
                        ForEach(ThemeName.allCases) { theme in
                            Text(theme.title).tag(theme.rawValue)
                        }
                    }
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("T3 Code's purple themes. Light or dark follows your phone.")
                }

                Section {
                    TextField("Pinned thread title", text: $model.settings.threadTitle)
                    Picker("Lives in", selection: Binding(get: { model.settings.projectId }, set: { model.choose(project: $0) })) {
                        Text("Automatic\(model.automaticProject.map { " (\($0.displayName))" } ?? "")").tag(String?.none)
                        ForEach(model.projects) { project in
                            Text(project.displayName).tag(Optional(project.projectId))
                        }
                    }
                    Picker("New threads run", selection: $model.settings.runtimeMode) {
                        Text("Server default").tag(RuntimeMode?.none)
                        ForEach(RuntimeMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(Optional(mode))
                        }
                    }
                    if let id = model.copilotThreadID {
                        LabeledContent("Thread", value: id).font(.caption).lineLimit(1).truncationMode(.middle)
                        Button("Start a fresh Copilot thread", role: .destructive) { model.resetCopilotThread() }
                    }
                } header: {
                    Text("Copilot thread")
                } footer: {
                    Text("The Copilot is a normal pinned thread in T3 Code, in your home folder project unless you pick another. Pick the model on the main screen; threads the Copilot starts use the same one.")
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
            .scrollContentBackground(.hidden)
            .background(ThemeBackground())
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
