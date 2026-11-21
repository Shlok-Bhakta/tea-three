import SwiftUI
import TeaThreeKit

enum ConnectionState: Equatable {
    case checking, connected, offline, signedOut

    @MainActor init(_ model: AppModel) {
        switch model.connection {
        case nil: self = .checking
        case .connected: self = .connected
        case .unreachable: self = model.isCheckingConnection ? .checking : .offline
        case .signedOut: self = .signedOut
        }
    }

    var color: Color {
        switch self {
        case .connected: .green
        case .checking: .yellow
        case .offline: .red
        case .signedOut: .orange
        }
    }
}

struct ConnectionDot: View {
    let state: ConnectionState
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(state.color)
            .frame(width: 7, height: 7)
            .opacity(state == .checking && dim ? 0.3 : 1)
            .animation(state == .checking ? .easeInOut(duration: 0.7).repeatForever() : .default, value: dim)
            .onAppear { dim = true }
    }
}

/// Tapped from the title: what's connected, how fast, and what to try when it isn't.
struct ConnectionDetails: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                ConnectionDot(state: ConnectionState(model))
                Text(title).font(.headline).foregroundStyle(theme.foreground)
            }
            VStack(alignment: .leading, spacing: 6) {
                row("Server", model.serverAddress)
                switch model.connection {
                case .connected(let latency)?:
                    row("Response", "\(Int((latency * 1000).rounded())) ms")
                case .unreachable(let reason)?, .signedOut(let reason)?:
                    row("Problem", reason)
                case nil:
                    EmptyView()
                }
                if let checked = model.connectionCheckedAt {
                    row("Checked", checked.formatted(.relative(presentation: .named)))
                }
                if model.outboxCount > 0 {
                    row("Waiting", "\(model.outboxCount) message\(model.outboxCount == 1 ? "" : "s") to send")
                }
            }
            if let hint {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(theme.foregroundSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                Task { await model.checkConnection() }
            } label: {
                HStack {
                    if model.isCheckingConnection { ProgressView().controlSize(.small) }
                    Text(model.isCheckingConnection ? "Checking…" : "Check again")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(theme.primary)
            .disabled(model.isCheckingConnection)
        }
        .padding(18)
        .frame(width: 300)
    }

    private var title: String {
        switch ConnectionState(model) {
        case .connected: "Connected to \(model.serverName)"
        case .checking: "Connecting…"
        case .offline: "Can't reach \(model.serverName)"
        case .signedOut: "Not signed in"
        }
    }

    private var hint: String? {
        switch ConnectionState(model) {
        case .offline:
            // 100.64.0.0/10 is Tailscale's range: the usual culprit is the VPN being off.
            let host = URL(string: model.serverAddress)?.host ?? ""
            let tailnet = host.hasPrefix("100.") || host.hasSuffix(".ts.net")
            return tailnet
                ? "Check that Tailscale is on and connected, and that you have internet. Messages you send now wait and go out once it's back."
                : "Check your internet connection. Messages you send now wait and go out once it's back."
        case .signedOut:
            return "Pair again from Settings."
        default:
            return nil
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(theme.foregroundSecondary)
            Spacer(minLength: 12)
            Text(value).foregroundStyle(theme.foreground).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}
