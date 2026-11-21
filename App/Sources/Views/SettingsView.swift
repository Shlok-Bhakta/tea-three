import Intents
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
                        Button("Start a fresh Clanker thread", role: .destructive) { model.resetCopilotThread() }
                    }
                } header: {
                    Text("Clanker thread")
                } footer: {
                    Text("The Clanker is a normal pinned thread in T3 Code, in your home folder project unless you pick another. Pick the model on the main screen; threads the Clanker starts use the same one.")
                }

                Section {
                    TextEditor(text: $model.settings.extraInstructions)
                        .frame(minHeight: 100)
                } header: {
                    Text("Notes for the Clanker")
                } footer: {
                    Text("For example: “Food logs go to the Health project using the food-log skill. Snooze anything I say to do later until tomorrow 9am.”")
                }

                Section {
                    Toggle("Speak replies", isOn: $model.settings.speakReplies)
                    VoiceDownloadRow()
                    NavigationLink {
                        VoicePicker().themed()
                    } label: {
                        LabeledContent("Voice", value: Speaker.selectedName)
                    }
                    LabeledContent("Pause before sending") {
                        Stepper(
                            String(format: "%.1f s", model.settings.turnPause ?? TurnDetector.defaultPause),
                            value: Binding(
                                get: { model.settings.turnPause ?? TurnDetector.defaultPause },
                                set: { model.settings.turnPause = $0 }
                            ),
                            in: 1.0...8.0, step: 0.5
                        )
                    }
                } header: {
                    Text("Voice")
                } footer: {
                    Text("After a finished sentence. If you trail off on “um”, “and”, “but”, or a comma, it waits about 3 s longer, and “wait” or “hold on” holds it longer still. A soft tick plays a second before sending; keep talking to continue. Say “send it” to send right away.")
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
                    // Read each time Settings opens, so a change in iOS Settings shows up.
                    Text(SendMessageHandler.isAvailable && INPreferences.siriAuthorizationStatus() == .authorized
                         ? "“Hey Siri, message Clanker saying …” sends it in one go. “Talk to Clanker” opens hands-free mode; put “Talk” on the Action button in Settings › Action Button › Shortcut."
                         : "“Hey Siri, tell Clanker”, then say the message. “Talk to Clanker” opens hands-free mode; put “Talk” on the Action button in Settings › Action Button › Shortcut.")
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
