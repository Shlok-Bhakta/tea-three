import SwiftUI
import TeaThreeKit

@main
struct TeaThreeApp: App {
    @State private var model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .themed()
                .onOpenURL { url in
                    // teathree://pair?pairingUrl=... (or a scanned t3code:// link)
                    PairingRouter.shared.pending = url.absoluteString
                }
                .task {
                    #if DEBUG
                    // `SIMCTL_CHILD_TEA_THREE_PAIRING_URL=… xcrun simctl launch …` pairs without taps.
                    if let url = ProcessInfo.processInfo.environment["TEA_THREE_PAIRING_URL"] {
                        PairingRouter.shared.pending = url
                    }
                    #endif
                    await model.refresh()
                }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    if phase == .active {
                        model.startMonitoring()
                        Task { await model.flushOutbox() }
                    } else if phase == .background {
                        model.stopMonitoring()
                    }
                }
        }
    }
}

/// Hands a pairing link from `onOpenURL` to the pairing screen.
@Observable
final class PairingRouter {
    static let shared = PairingRouter()
    var pending: String?
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isPaired {
            HomeView()
        } else {
            NavigationStack {
                PairingView()
                    .scrollContentBackground(.hidden)
                    .background(ThemeBackground())
            }
        }
    }
}
