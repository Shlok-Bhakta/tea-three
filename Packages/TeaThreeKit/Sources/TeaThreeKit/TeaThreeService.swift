import Foundation

/// The entry point the app, App Intents, CarPlay, and CLI share.
public struct TeaThreeService: Sendable {
    public let credentials: any CredentialStoring
    public let store: SharedStore
    let transport: HTTPTransport

    public init(credentials: any CredentialStoring, store: SharedStore, transport: HTTPTransport = URLSessionTransport()) {
        self.credentials = credentials
        self.store = store
        self.transport = transport
    }

    public var isPaired: Bool { credentials.load() != nil }

    public func pair(_ link: PairingLink, access: MCPOAuth.Access = .auto) async throws -> T3Credential {
        let credential = try await MCPOAuth(transport: transport).pair(link, access: access)
        try credentials.save(credential)
        // A new server means the old Copilot thread id means nothing.
        if store.copilotThreadID != nil { store.copilotThreadID = nil }
        return credential
    }

    /// Installs a credential baked into the app at build time (see `ios-build.sh`),
    /// so a fresh build arrives already paired. Each bundled token is adopted once:
    /// pairing by hand or unpairing afterwards isn't undone on the next launch.
    @discardableResult
    public func adoptBundledCredential(at url: URL?) -> Bool {
        guard let url, let data = try? Data(contentsOf: url),
              let credential = try? JSONDecoder().decode(T3Credential.self, from: data),
              !credential.isExpired,
              store.adoptedBundledToken != SharedStore.fingerprint(credential.accessToken),
              (try? credentials.save(credential)) != nil else { return false }
        store.adoptedBundledToken = SharedStore.fingerprint(credential.accessToken)
        store.copilotThreadID = nil
        return true
    }

    public func unpair() {
        credentials.clear()
        store.copilotThreadID = nil
    }

    public func client() throws -> T3Client {
        guard let credential = credentials.load() else { throw T3Error.unauthorized("no credential") }
        if credential.isExpired { throw T3Error.unauthorized("token expired") }
        return T3Client(credential: credential, transport: transport)
    }

    public func copilot() throws -> Copilot {
        Copilot(client: try client(), settings: store.settings, store: store)
    }

    public struct DropResult: Sendable {
        /// Spoken by Siri. Kept to a few words.
        public let dialog: String
        public let delivered: Bool
    }

    /// Siri's fire-and-forget path. Never throws: if T3 can't be reached the
    /// request goes to the outbox and is retried next time the app runs.
    public func drop(_ text: String) async -> DropResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return DropResult(dialog: "I didn't catch anything.", delivered: false) }
        do {
            let copilot = try copilot()
            await copilot.flushOutbox()
            try await copilot.send(trimmed, source: .siri)
            return DropResult(dialog: "Sent.", delivered: true)
        } catch let error as T3Error {
            if case .unauthorized = error { return DropResult(dialog: error.spokenDescription, delivered: false) }
            store.enqueue(trimmed, source: .siri)
            return DropResult(dialog: "\(error.spokenDescription) I saved it and will send it later.", delivered: false)
        } catch {
            store.enqueue(trimmed, source: .siri)
            return DropResult(dialog: "Something went wrong. I saved it for later.", delivered: false)
        }
    }

    /// Checks the server's tool schemas against `ToolContract`.
    public func checkContract() async throws -> [ToolContract.Violation] {
        let client = try client()
        let violations = ToolContract.check(try await client.mcp.listTools())
        let version = await client.mcp.serverInfo?.version ?? "unknown"
        store.lastContractReport = violations.isEmpty
            ? "T3 Code \(version): compatible"
            : "T3 Code \(version): " + violations.map(\.description).joined(separator: "; ")
        return violations
    }
}
