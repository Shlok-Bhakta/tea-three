import Foundation
import Observation
import UIKit
import TeaThreeKit

/// The one service instance. Nonisolated so App Intents can reach it from
/// whatever executor they run on.
enum Shared {
    // Intents run in-process, so the app's own Keychain and defaults are
    // enough. Move to an App Group if a widget/control extension is added.
    nonisolated static let service: TeaThreeService = {
        let service = TeaThreeService(credentials: KeychainCredentialStore(), store: SharedStore(defaults: .standard))
        // Builds made with `ios-build.sh` can carry a login, so they arrive paired.
        service.adoptBundledCredential(at: Bundle.main.url(forResource: "TeaThreeBootstrap", withExtension: "json"))
        return service
    }()
}

/// App-wide state, shared by the phone UI, the CarPlay scene, and App Intents
/// (which run in the app's process).
@Observable
final class AppModel {
    static let shared = AppModel()

    let service: TeaThreeService
    let voice: VoiceSession

    private(set) var credential: T3Credential?
    var settings: CopilotSettings {
        didSet { service.store.settings = settings }
    }
    private(set) var capabilities: OrchestratorCapabilities?
    private(set) var projects: [ProjectListResult.Project] = []
    private(set) var contractReport: String?
    private(set) var outboxCount = 0
    /// Photos that go out with the next message, typed or spoken.
    private(set) var pendingPhotos: [PendingPhoto] = []
    var lastError: String?

    var isPaired: Bool { credential != nil }

    private init() {
        let service = Shared.service
        self.service = service
        self.voice = VoiceSession(service: service)
        self.credential = service.credentials.load()
        self.settings = service.store.settings
        self.contractReport = service.store.lastContractReport
        self.outboxCount = service.store.outbox.count
        voice.takeAttachments = { [weak self] in self?.takePendingAttachments() ?? [] }
    }

    // MARK: Pairing

    func pair(_ link: PairingLink, access: MCPOAuth.Access) async throws {
        credential = try await service.pair(link, access: access)
        await refresh()
    }

    func unpair() {
        voice.stop()
        service.unpair()
        credential = nil
        capabilities = nil
        projects = []
    }

    // MARK: Server state

    func refresh() async {
        guard isPaired else { return }
        do {
            let client = try service.client()
            async let capabilities = client.capabilities()
            async let projects = client.projects()
            self.capabilities = try await capabilities
            self.projects = try await projects
            _ = try await service.checkContract()
            contractReport = service.store.lastContractReport
            lastError = nil
        } catch let error as T3Error {
            lastError = error.errorDescription
            if case .unauthorized = error { credential = nil }
        } catch {
            lastError = error.localizedDescription
        }
        await flushOutbox()
    }

    func flushOutbox() async {
        if let copilot = try? service.copilot() {
            await copilot.flushOutbox()
        }
        outboxCount = service.store.outbox.count
    }

    // MARK: Photos

    func addPhoto(_ image: UIImage) {
        guard pendingPhotos.count < 8, let photo = PendingPhoto(image) else { return }
        pendingPhotos.append(photo)
    }

    func removePhoto(_ id: UUID) {
        pendingPhotos.removeAll { $0.id == id }
    }

    /// Hands the pending photos to a message and clears them.
    func takePendingAttachments() -> [OutgoingAttachment] {
        defer { pendingPhotos = [] }
        return pendingPhotos.map(\.attachment)
    }

    // MARK: Choices

    /// The model for the Copilot, and so for every thread it starts (they inherit it).
    /// Applied to the existing Copilot thread right away.
    func choose(model selection: ModelSelection) {
        settings.copilotModel = selection
        Task {
            do {
                try await service.copilot().use(selection)
                lastError = nil
            } catch let error as T3Error {
                lastError = error.errorDescription
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    /// A thread can't move projects, so a new project means a new Copilot thread.
    func choose(project projectId: String?) {
        guard projectId != settings.projectId else { return }
        settings.projectId = projectId
        resetCopilotThread()
    }

    /// Where the Copilot lives when no project is chosen.
    var automaticProject: ProjectListResult.Project? { Copilot.homeProject(in: projects) }

    /// Forgets the cached Copilot thread; the next message finds or recreates it.
    func resetCopilotThread() {
        service.store.copilotThreadID = nil
    }

    var copilotThreadID: String? { service.store.copilotThreadID }
}
