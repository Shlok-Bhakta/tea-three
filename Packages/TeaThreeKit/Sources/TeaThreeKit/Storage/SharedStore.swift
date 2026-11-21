import CryptoKit
import Foundation

/// State shared by the app, its App Intents, and the CarPlay scene through
/// an App Group. The credential lives in the Keychain, not here.
public final class SharedStore: @unchecked Sendable {
    public static let appGroup = "group.com.shlokbhakta.teathree"

    public struct OutboxItem: Sendable, Codable, Equatable, Identifiable {
        public let id: String
        public let text: String
        public let source: CopilotPrompts.Source
        public let createdAt: Date
    }

    let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The App Group store, falling back to standard defaults (e.g. in `swift test`).
    public static func shared() -> SharedStore {
        SharedStore(defaults: UserDefaults(suiteName: appGroup) ?? .standard)
    }

    private enum Key {
        static let settings = "copilot.settings"
        static let threadID = "copilot.threadId"
        static let readCursor = "copilot.readCursor"
        static let outbox = "outbox"
        static let lastContractReport = "contract.lastReport"
        static let adoptedBundledToken = "bootstrap.adoptedToken"
    }

    public var settings: CopilotSettings {
        get { decode(CopilotSettings.self, Key.settings) ?? .default }
        set { encode(newValue, Key.settings) }
    }

    public var copilotThreadID: String? {
        get { defaults.string(forKey: Key.threadID) }
        set {
            defaults.set(newValue, forKey: Key.threadID)
            defaults.removeObject(forKey: Key.readCursor)
        }
    }

    public func readCursor(threadId: String) -> Int? {
        guard let stored = defaults.dictionary(forKey: Key.readCursor), stored["threadId"] as? String == threadId else {
            return nil
        }
        return stored["position"] as? Int
    }

    func setReadCursor(_ position: Int, threadId: String) {
        defaults.set(["threadId": threadId, "position": position], forKey: Key.readCursor)
    }

    // MARK: Outbox

    public var outbox: [OutboxItem] {
        lock.withLock { decode([OutboxItem].self, Key.outbox) ?? [] }
    }

    /// `id` is the send's retry key: reuse the live attempt's so a send the
    /// server did get isn't run twice.
    public func enqueue(_ text: String, source: CopilotPrompts.Source, id: String = UUID().uuidString) {
        lock.withLock {
            var items = decode([OutboxItem].self, Key.outbox) ?? []
            items.append(OutboxItem(id: id, text: text, source: source, createdAt: Date()))
            encode(items, Key.outbox)
        }
    }

    public func removeFromOutbox(id: String) {
        lock.withLock {
            let items = (decode([OutboxItem].self, Key.outbox) ?? []).filter { $0.id != id }
            encode(items, Key.outbox)
        }
    }

    // MARK: Contract

    public var lastContractReport: String? {
        get { defaults.string(forKey: Key.lastContractReport) }
        set { defaults.set(newValue, forKey: Key.lastContractReport) }
    }

    // MARK: Bundled credential

    /// Fingerprint of the last build-time token adopted, so it's adopted only once.
    var adoptedBundledToken: String? {
        get { defaults.string(forKey: Key.adoptedBundledToken) }
        set { defaults.set(newValue, forKey: Key.adoptedBundledToken) }
    }

    static func fingerprint(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Helpers

    private func decode<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func encode<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }
}
