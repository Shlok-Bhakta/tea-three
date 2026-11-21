import Intents
import UIKit
import TeaThreeKit

/// SiriKit messaging, so one breath does it: "Hey Siri, message Clanker
/// saying I had a burrito for lunch." The only recipient is the
/// Clanker, so whatever name Siri heard (or none) resolves to it. Delivery is
/// the same fire-and-forget drop as the "Tell Clanker" shortcut: queued if
/// the server can't be reached.
final class SendMessageHandler: NSObject, INSendMessageIntentHandling {
    static let clanker = INPerson(
        personHandle: INPersonHandle(value: "clanker", type: .unknown),
        nameComponents: nil,
        displayName: "Clanker",
        image: nil,
        contactIdentifier: nil,
        customIdentifier: "clanker"
    )

    /// Asks for Siri access once, and teaches Siri the name "Clanker".
    /// Only with the SiriKit entitlement: without it, INPreferences raises an
    /// exception and kills the app.
    static func prepare() {
        guard isAvailable else { return }
        if INPreferences.siriAuthorizationStatus() == .notDetermined {
            INPreferences.requestSiriAuthorization { _ in }
        }
        let name = INSpeakableString(vocabularyIdentifier: "clanker", spokenPhrase: "Clanker", pronunciationHint: "clanker")
        INVocabulary.shared().setVocabulary(NSOrderedSet(object: name), of: .contactName)
    }

    /// Tells iOS a message went to Clanker in this app, so Siri learns that
    /// "message Clanker" means here rather than Messages.
    static func donate(_ text: String) {
        guard isAvailable else { return }
        let intent = INSendMessageIntent(
            recipients: [clanker], outgoingMessageType: .outgoingMessageText, content: text,
            speakableGroupName: nil, conversationIdentifier: "clanker", serviceName: nil, sender: nil, attachments: nil
        )
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .outgoing
        interaction.donate(completion: nil)
    }

    /// Whether this build's profile grants SiriKit, which "message Clanker" needs.
    static let isAvailable: Bool = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return false }
        return data.range(of: Data("com.apple.developer.siri".utf8)) != nil
    }()

    func resolveRecipients(for intent: INSendMessageIntent) async -> [INSendMessageRecipientResolutionResult] {
        [.success(with: Self.clanker)]
    }

    func resolveContent(for intent: INSendMessageIntent) async -> INStringResolutionResult {
        guard let content = intent.content?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
            return .needsValue()
        }
        return .success(with: content)
    }

    func handle(intent: INSendMessageIntent) async -> INSendMessageIntentResponse {
        guard let content = intent.content, !content.isEmpty else {
            return INSendMessageIntentResponse(code: .failure, userActivity: nil)
        }
        // Sent, or saved to send later; only a lost login means it didn't go anywhere.
        let result = await Shared.service.drop(content)
        return INSendMessageIntentResponse(code: result.needsApp ? .failureRequiringAppLaunch : .success, userActivity: nil)
    }
}

/// Hands SiriKit intents to their in-app handlers.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        intent is INSendMessageIntent ? SendMessageHandler() : nil
    }
}
