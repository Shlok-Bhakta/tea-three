import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The one seam between TeaThreeKit and the network, so tests can replay fixtures.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw T3Error.transport("Non-HTTP response from \(request.url?.absoluteString ?? "?")")
        }
        return (data, http)
    }
}

public enum T3Error: Error, Sendable, Equatable, LocalizedError {
    /// Network-level failure: server unreachable, timeout, bad response.
    case transport(String)
    /// The token is missing, expired, or revoked. The user must pair again.
    case unauthorized(String)
    /// The server answered with something we don't understand. Likely protocol drift.
    case protocolMismatch(String)
    /// A JSON-RPC error from the MCP layer.
    case rpc(code: Int, message: String)
    /// A T3 tool ran and reported failure (`isError: true`).
    case tool(name: String, code: String?, message: String)
    /// Bad pairing input (URL, code).
    case pairing(String)
    /// No model picked in the app yet, so the Copilot thread can't start.
    case needsModel

    public var errorDescription: String? {
        switch self {
        case .transport(let message): "Couldn't reach T3 Code: \(message)"
        case .unauthorized(let message): "Not paired with T3 Code (\(message)). Pair again in Clanker."
        case .protocolMismatch(let message): "T3 Code answered in an unexpected format: \(message)"
        case .rpc(let code, let message): "T3 Code MCP error \(code): \(message)"
        case .tool(let name, let code, let message): "\(name) failed\(code.map { " (\($0))" } ?? ""): \(message)"
        case .pairing(let message): message
        case .needsModel: "Pick a model in Clanker first."
        }
    }

    /// Spoken by Siri or the voice screen. Short on purpose.
    public var spokenDescription: String {
        switch self {
        case .transport: "I couldn't reach T3 Code."
        case .unauthorized: "Clanker isn't paired anymore. Open the app to pair again."
        case .protocolMismatch: "T3 Code changed in a way I don't understand yet."
        case .rpc, .tool: "T3 Code returned an error."
        case .pairing(let message): message
        case .needsModel: "Pick a model in the Clanker app first."
        }
    }
}
