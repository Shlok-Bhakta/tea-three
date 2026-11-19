import CarPlay
import TeaThreeKit

/// CarPlay "voice-based conversation" app (iOS 26.4+): one voice-control
/// template, no text replies on screen, per Apple's CarPlay guidelines.
///
/// Only appears in the car once Apple grants the
/// `com.apple.developer.carplay-voice-based-conversation` entitlement and the
/// app is signed with `App/TeaThree-CarPlay.entitlements`. Until then, use
/// "Hey Siri, tell Tea Three…" in the car; it needs no entitlement.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var template: CPVoiceControlTemplate?

    private enum State: String {
        case idle, listening, thinking, speaking
    }

    func templateApplicationScene(
        _ scene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        let voice = AppModel.shared.voice

        guard AppModel.shared.isPaired else {
            let template = CPInformationTemplate(
                title: "Tea Three",
                layout: .leading,
                items: [CPInformationItem(title: "Not paired", detail: "Pair with T3 Code on your iPhone while parked.")],
                actions: []
            )
            interfaceController.setRootTemplate(template, animated: false, completion: nil)
            return
        }

        let template = CPVoiceControlTemplate(voiceControlStates: [
            makeState(.idle, titles: ["Tap to talk", "Ready"], image: "mic.circle", buttons: [startButton()]),
            makeState(.listening, titles: ["Listening…"], image: "waveform", repeats: true, buttons: [stopButton()]),
            makeState(.thinking, titles: ["Working on it…", "Thinking…"], image: "ellipsis.circle", repeats: true, buttons: [stopButton()]),
            makeState(.speaking, titles: ["Copilot"], image: "speaker.wave.2", repeats: true, buttons: [stopButton()]),
        ])
        self.template = template
        interfaceController.setRootTemplate(template, animated: false, completion: nil)

        voice.onPhaseChange = { [weak self] phase in self?.show(phase) }
        // Start listening as soon as the driver opens the app: that's the whole app.
        voice.start()
        show(voice.phase)
    }

    func templateApplicationScene(
        _ scene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        AppModel.shared.voice.onPhaseChange = nil
        AppModel.shared.voice.stop()
        self.interfaceController = nil
        template = nil
    }

    private func show(_ phase: VoiceSession.Phase) {
        let state: State = switch phase {
        case .idle: .idle
        case .listening: .listening
        case .thinking: .thinking
        case .speaking: .speaking
        }
        template?.activateVoiceControlState(withIdentifier: state.rawValue)
    }

    private func makeState(_ state: State, titles: [String], image: String, repeats: Bool = false, buttons: [CPButton]) -> CPVoiceControlState {
        let voiceState = CPVoiceControlState(
            identifier: state.rawValue,
            titleVariants: titles,
            image: UIImage(systemName: image),
            repeats: repeats
        )
        if #available(iOS 26.4, *) {
            voiceState.actionButtons = buttons
        }
        return voiceState
    }

    private func startButton() -> CPButton {
        CPButton(image: UIImage(systemName: "mic.fill")!) { _ in AppModel.shared.voice.start() }
    }

    private func stopButton() -> CPButton {
        CPButton(image: UIImage(systemName: "stop.fill")!) { _ in AppModel.shared.voice.stop() }
    }
}
