import CryptoKit
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The credential Tea Three keeps: a bearer token valid only for `/mcp`.
public struct T3Credential: Sendable, Codable, Equatable {
    public var serverURL: URL
    public var accessToken: String
    public var expiresAt: Date?
    public var scope: String?
    public var clientID: String
    public var environmentID: String?
    public var environmentLabel: String?

    public var mcpEndpoint: URL { serverURL.appendingPathComponent("mcp") }

    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }
}

/// What `GET /.well-known/t3/environment` says about a server. Unauthenticated.
public struct T3Environment: Sendable, Codable, Equatable {
    public let environmentId: String
    public let label: String
    public let serverVersion: String
    public let orchestrationProtocolVersion: Int?
}

/// Pairs Tea Three with a T3 Code server using the server's own MCP OAuth
/// (RFC 7591 registration + PKCE), approving with a `t3 pair` code instead
/// of a browser. The resulting token is scoped to orchestration and works only
/// on `/mcp`, so a leaked phone token can't touch settings or the filesystem API.
public struct MCPOAuth: Sendable {
    public static let redirectURI = "http://127.0.0.1/tea-three/callback"

    public enum Access: String, Sendable, CaseIterable {
        /// Lets the Copilot start threads that run without asking for approvals.
        case auto
        case approvalRequired = "approval-required"
    }

    let transport: HTTPTransport

    public init(transport: HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    public func discover(_ serverURL: URL) async throws -> T3Environment {
        let url = serverURL.appendingPathComponent(".well-known/t3/environment")
        let (data, response) = try await send(URLRequest(url: url, timeoutInterval: 10))
        guard response.statusCode == 200 else {
            throw T3Error.transport("\(url.host ?? "server") answered HTTP \(response.statusCode). Is this a T3 Code server?")
        }
        do {
            return try JSONDecoder().decode(T3Environment.self, from: data)
        } catch {
            throw T3Error.protocolMismatch("environment descriptor: \(error)")
        }
    }

    public func pair(_ link: PairingLink, access: Access = .auto, clientName: String = "Tea Three") async throws -> T3Credential {
        let environment = try await discover(link.serverURL)

        // 1. Dynamic client registration.
        let registration: JSONValue = try await postJSON(
            link.serverURL.appendingPathComponent("oauth/mcp/register"),
            ["client_name": .string(clientName), "redirect_uris": [.string(Self.redirectURI)]]
        )
        guard let clientID = registration["client_id"]?.stringValue else {
            throw T3Error.protocolMismatch("registration returned no client_id")
        }

        // 2. Approve with the pairing code. The server answers with the redirect
        //    it would have sent a browser; we just read the code out of it.
        let pkce = PKCE()
        let state = UUID().uuidString
        let decision: JSONValue = try await postJSON(
            link.serverURL.appendingPathComponent("oauth/mcp/decision"),
            [
                "authorization": [
                    "response_type": "code",
                    "client_id": .string(clientID),
                    "redirect_uri": .string(Self.redirectURI),
                    "code_challenge": .string(pkce.challenge),
                    "code_challenge_method": "S256",
                    "state": .string(state),
                    "resource": .string(link.serverURL.appendingPathComponent("mcp").absoluteString),
                ],
                "decision": ["_tag": "pairing-code", "access": .string(access.rawValue), "code": .string(link.code)],
            ]
        )
        guard
            let redirect = decision["redirectTo"]?.stringValue,
            let items = URLComponents(string: redirect)?.queryItems
        else {
            throw T3Error.protocolMismatch("authorization decision returned no redirect")
        }
        if let error = items.first(where: { $0.name == "error" })?.value {
            throw T3Error.pairing("T3 Code refused the pairing: \(error)")
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw T3Error.protocolMismatch("authorization redirect had no code")
        }
        guard items.first(where: { $0.name == "state" })?.value == state else {
            throw T3Error.pairing("Pairing state mismatch.")
        }

        // 3. Exchange the code for a bearer token.
        var tokenRequest = URLRequest(url: link.serverURL.appendingPathComponent("oauth/mcp/token"), timeoutInterval: 15)
        tokenRequest.httpMethod = "POST"
        tokenRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        tokenRequest.httpBody = Self.formEncode([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "client_id": clientID,
            "code_verifier": pkce.verifier,
        ])
        let (data, response) = try await send(tokenRequest)
        guard response.statusCode == 200 else {
            throw T3Error.pairing("Token exchange failed (HTTP \(response.statusCode)): \(MCPClient.authReason(data) ?? "")")
        }
        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        return T3Credential(
            serverURL: link.serverURL,
            accessToken: token.access_token,
            expiresAt: token.expires_in.map { Date().addingTimeInterval(TimeInterval($0)) },
            scope: token.scope,
            clientID: clientID,
            environmentID: environment.environmentId,
            environmentLabel: environment.label
        )
    }

    struct TokenResponse: Decodable {
        let access_token: String
        let token_type: String?
        let expires_in: Int?
        let scope: String?
    }

    // MARK: - Helpers

    private func postJSON(_ url: URL, _ body: JSONValue) async throws -> JSONValue {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else {
            let reason = MCPClient.authReason(data) ?? String(decoding: data.prefix(200), as: UTF8.self)
            if response.statusCode == 400 || response.statusCode == 401 || response.statusCode == 403 {
                throw T3Error.pairing("T3 Code rejected the pairing code (\(reason)). Codes last 5 minutes and work once.")
            }
            throw T3Error.transport("HTTP \(response.statusCode) from \(url.path): \(reason)")
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.send(request)
        } catch let error as T3Error {
            throw error
        } catch {
            throw T3Error.transport(error.localizedDescription)
        }
    }

    static func formEncode(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return Data(
            fields.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
                .joined(separator: "&").utf8
        )
    }
}

struct PKCE {
    let verifier: String
    let challenge: String

    init() {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        verifier = Data(bytes).base64URLEncoded
        challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
