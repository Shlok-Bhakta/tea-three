import SwiftUI
import TeaThreeKit

/// Model and reasoning picker, modeled on T3 Code's composer model control.
/// Models and their options (reasoning effort, fast mode, ...) come live from
/// the server's `orchestrator_capabilities`, so new ones show up on their own.
struct ModelSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    private var providers: [OrchestratorCapabilities.Provider] {
        model.capabilities?.providers.filter { !$0.models.isEmpty } ?? []
    }

    private var current: (provider: OrchestratorCapabilities.Provider, model: OrchestratorCapabilities.Provider.Model)? {
        model.settings.copilotModel.flatMap { model.capabilities?.lookup($0) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let current, let options = current.model.options, !options.isEmpty {
                    Section {
                        ForEach(options) { option in
                            OptionRow(option: option)
                        }
                    } header: {
                        Text(current.model.displayName)
                    }
                }
                ForEach(providers) { provider in
                    Section {
                        ForEach(provider.models) { option in
                            let selected = current?.provider.id == provider.id && current?.model.id == option.id
                            Button {
                                select(option, in: provider)
                            } label: {
                                HStack(spacing: 12) {
                                    ProviderBadge(provider: provider)
                                    Text(option.displayName).foregroundStyle(theme.foreground)
                                    Spacer()
                                    if selected {
                                        Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(theme.primaryText)
                                    }
                                }
                            }
                        }
                    } header: {
                        Text(provider.displayName ?? provider.providerInstanceId)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .listRowBackground(theme.card)
            .navigationTitle("Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
    }

    /// Switching models keeps options the new model also supports.
    private func select(_ option: OrchestratorCapabilities.Provider.Model, in provider: OrchestratorCapabilities.Provider) {
        let kept = (model.settings.copilotModel?.options ?? [:]).filter { id, value in
            option.options?.contains { $0.id == id && $0.values.contains(value) } ?? false
        }
        model.choose(model: ModelSelection(instanceId: provider.providerInstanceId, model: option.id, options: kept.isEmpty ? nil : kept))
    }
}

/// One model option: a toggle for on/off options, a menu for the rest.
private struct OptionRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let option: OrchestratorCapabilities.Provider.Model.Option

    private var value: JSONValue? {
        model.settings.copilotModel?.options?[option.id] ?? option.default
    }

    var body: some View {
        if option.isToggle {
            Toggle(ModelOptionText.title(option.id), isOn: Binding(
                get: { value == .bool(true) },
                set: { set(.bool($0)) }
            ))
            .foregroundStyle(theme.foreground)
        } else {
            Picker(ModelOptionText.title(option.id), selection: Binding(
                get: { value ?? option.values.first ?? .null },
                set: { set($0) }
            )) {
                ForEach(option.values, id: \.self) { value in
                    Text(ModelOptionText.value(value)).tag(value)
                }
            }
            .pickerStyle(.menu)
            .foregroundStyle(theme.foreground)
        }
    }

    private func set(_ value: JSONValue) {
        guard var selection = model.settings.copilotModel else { return }
        var options = selection.options ?? [:]
        // The default stays implicit, so a server-side default change still applies.
        options[option.id] = value == option.default || (option.default == nil && value == .bool(false)) ? nil : value
        selection.options = options.isEmpty ? nil : options
        model.choose(model: selection)
    }
}

/// A small monogram for a provider, in the theme's accent.
struct ProviderBadge: View {
    @Environment(\.theme) private var theme
    let provider: OrchestratorCapabilities.Provider

    /// A distinct symbol per provider kind; a monogram for the rest.
    private var symbol: String? {
        switch provider.driverKind ?? provider.providerInstanceId {
        case "claudeAgent": "asterisk"
        case "codex": "chevron.left.forwardslash.chevron.right"
        case "cursor": "cursorarrow"
        case "grok": "bolt.fill"
        case "opencode": "curlybraces"
        default: nil
        }
    }

    var body: some View {
        Group {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 11, weight: .bold))
            } else {
                Text(String((provider.displayName ?? provider.providerInstanceId).prefix(1)).uppercased())
                    .font(.system(size: 12, weight: .bold, design: .rounded))
            }
        }
        .foregroundStyle(theme.primaryText)
        .frame(width: 22, height: 22)
        .background(theme.primary.opacity(0.18), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

enum ModelOptionText {
    static func title(_ id: String) -> String {
        switch id {
        case "effort", "reasoningEffort", "reasoning": "Reasoning"
        case "fastMode": "Fast mode"
        case "serviceTier": "Service tier"
        case "ultracode": "Ultracode"
        default:
            // camelCase → "Camel case"
            id.reduce(into: "") { text, character in
                text += character.isUppercase ? " " + character.lowercased() : String(character)
            }.capitalizedFirst
        }
    }

    static func value(_ value: JSONValue) -> String {
        switch value {
        case .string("xhigh"): "Extra high"
        case .string(let text): text.capitalizedFirst
        case .bool(let on): on ? "On" : "Off"
        default: "\(value)"
        }
    }

    /// "Opus 5.5 · High": the model plus its reasoning level, for the composer pill.
    static func summary(_ selection: ModelSelection, in capabilities: OrchestratorCapabilities?) -> String {
        guard let found = capabilities?.lookup(selection) else { return selection.model }
        let name = found.model.displayName.replacingOccurrences(of: "Claude ", with: "")
        guard let reasoning = found.model.options?.first(where: { !$0.isToggle && title($0.id) == "Reasoning" }),
              let level = selection.options?[reasoning.id] ?? reasoning.default
        else { return name }
        return "\(name) · \(value(level))"
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
