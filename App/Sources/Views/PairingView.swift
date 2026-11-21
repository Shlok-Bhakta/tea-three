import SwiftUI
import TeaThreeKit
import VisionKit

struct PairingView: View {
    @Environment(AppModel.self) private var model
    @State private var router = PairingRouter.shared
    @State private var linkText = ""
    @State private var server = ""
    @State private var code = ""
    @State private var access: MCPOAuth.Access = .auto
    @State private var scanning = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("On your Mac, run")
                    Text("t3 pair")
                        .font(.system(.body, design: .monospaced))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    Text("then scan its QR code, or paste the pairing URL. Add `--tailscale` to reach your Mac from anywhere on your tailnet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)

                if DataScannerViewController.isSupported {
                    Button("Scan QR code", systemImage: "qrcode.viewfinder") { scanning = true }
                }
            }

            Section("Pairing URL") {
                TextField("http://100.x.y.z:3773/pair#token=…", text: $linkText, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button("Paste") { linkText = UIPasteboard.general.string ?? "" }
            }

            Section("Or type it") {
                TextField("Server (100.x.y.z:3773 or mac.tailnet.ts.net)", text: $server)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("Pairing code", text: $code)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            }

            Section {
                Picker("Clanker permissions", selection: $access) {
                    Text("Run without asking").tag(MCPOAuth.Access.auto)
                    Text("Ask for approvals").tag(MCPOAuth.Access.approvalRequired)
                }
            } footer: {
                Text("Tea Three gets an orchestration-only token: it can read and run threads, nothing else. “Ask for approvals” means threads it starts stop and wait for you in T3 Code, which doesn't work hands-free.")
            }

            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }

            Section {
                Button {
                    Task { await pair() }
                } label: {
                    HStack {
                        Text("Pair with T3 Code")
                        Spacer()
                        if working { ProgressView() }
                    }
                }
                .disabled(working || (linkText.isEmpty && (server.isEmpty || code.isEmpty)))
            }
        }
        .navigationTitle("Tea Three")
        .sheet(isPresented: $scanning) {
            QRScanner { scanned in
                scanning = false
                linkText = scanned
                Task { await pair() }
            }
            .ignoresSafeArea()
        }
        .onChange(of: router.pending, initial: true) { _, pending in
            guard let pending else { return }
            router.pending = nil
            linkText = pending
            Task { await pair() }
        }
    }

    private func pair() async {
        working = true
        defer { working = false }
        do {
            let link = linkText.isEmpty ? try PairingLink(server: server, code: code) : try PairingLink.parse(linkText)
            try await model.pair(link, access: access)
            error = nil
        } catch let failure as T3Error {
            error = failure.errorDescription
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// VisionKit's live QR scanner, returning the first payload it sees.
struct QRScanner: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .fast,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        try? controller.startScanning()
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void
        private var done = false

        init(onScan: @escaping (String) -> Void) {
            self.onScan = onScan
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for item in addedItems {
                if case .barcode(let barcode) = item, let payload = barcode.payloadStringValue {
                    done = true
                    dataScanner.stopScanning()
                    onScan(payload)
                    return
                }
            }
        }
    }
}
