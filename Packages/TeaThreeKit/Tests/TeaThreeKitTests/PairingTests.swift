import CryptoKit
import Foundation
import Testing
@testable import TeaThreeKit

@Suite("Pairing")
struct PairingTests {
    @Test("parses the QR pairing URL")
    func qrURL() throws {
        let link = try PairingLink.parse("http://192.168.1.5:3773/pair#token=K7Q2M9XRT4ZP")
        #expect(link.serverURL.absoluteString == "http://192.168.1.5:3773")
        #expect(link.code == "K7Q2M9XRT4ZP")
    }

    @Test("parses the t3code:// app link and our own scheme")
    func appLinks() throws {
        let inner = "https://mac.tail1234.ts.net/pair#token=K7Q2M9XRT4ZP"
        let encoded = inner.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        for scheme in ["t3code", "t3code-preview", "teathree"] {
            let link = try PairingLink.parse("\(scheme)://pair?pairingUrl=\(encoded)")
            #expect(link.serverURL.absoluteString == "https://mac.tail1234.ts.net")
            #expect(link.code == "K7Q2M9XRT4ZP")
        }
    }

    @Test("accepts the token in the query and hosted ?host= links")
    func queryAndHosted() throws {
        #expect(try PairingLink.parse("http://10.0.0.2:3773/pair?token=ABCDEFGH2345").code == "ABCDEFGH2345")
        let hosted = try PairingLink.parse("https://app.t3.codes/pair?host=https%3A%2F%2Fmac.ts.net&label=x#token=ABCDEFGH2345")
        #expect(hosted.serverURL.absoluteString == "https://mac.ts.net")
    }

    @Test("normalizes typed server addresses")
    func normalizeServer() throws {
        #expect(try PairingLink.normalizeServer("100.64.0.7:3773").absoluteString == "http://100.64.0.7:3773")
        #expect(try PairingLink.normalizeServer("mac.tail1234.ts.net").absoluteString == "https://mac.tail1234.ts.net")
        #expect(try PairingLink.normalizeServer("http://mac.local:3773/").absoluteString == "http://mac.local:3773")
    }

    @Test("cleans up typed codes and rejects junk")
    func codes() throws {
        let link = try PairingLink(serverURL: URL(string: "http://10.0.0.2:3773")!, code: " k7q2-m9xr-t4zp ")
        #expect(link.code == "K7Q2M9XRT4ZP")
        #expect(throws: T3Error.self) { try PairingLink(serverURL: URL(string: "http://10.0.0.2")!, code: "abc") }
        #expect(throws: T3Error.self) { try PairingLink.parse("http://10.0.0.2:3773/pair") }
        #expect(throws: T3Error.self) { try PairingLink.parse("ftp://nope") }
    }

    @Test("full MCP OAuth exchange with PKCE")
    func oauthFlow() async throws {
        let server = FakeOAuthServer()
        let link = try PairingLink.parse("http://10.0.0.2:3773/pair#token=K7Q2M9XRT4ZP")
        let credential = try await MCPOAuth(transport: server).pair(link)

        #expect(credential.accessToken == "issued-token")
        #expect(credential.mcpEndpoint.absoluteString == "http://10.0.0.2:3773/mcp")
        #expect(credential.environmentLabel == "Test Mac")
        #expect(credential.expiresAt! > Date().addingTimeInterval(29 * 86_400))
        #expect(server.paths == ["/.well-known/t3/environment", "/oauth/mcp/register", "/oauth/mcp/decision", "/oauth/mcp/token"])
        #expect(server.verifiedPKCE)
        #expect(server.decisionCode == "K7Q2M9XRT4ZP")
    }

    @Test("a rejected code becomes a readable pairing error")
    func rejectedCode() async throws {
        let server = FakeOAuthServer()
        server.rejectDecision = true
        let link = try PairingLink.parse("http://10.0.0.2:3773/pair#token=K7Q2M9XRT4ZP")
        await #expect {
            try await MCPOAuth(transport: server).pair(link)
        } throws: { error in
            guard case T3Error.pairing(let message) = error else { return false }
            return message.contains("5 minutes")
        }
    }
}

/// Mimics `/oauth/mcp/*` on a T3 Code server closely enough to check our side.
final class FakeOAuthServer: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var challenge: String?
    private(set) var paths: [String] = []
    private(set) var verifiedPKCE = false
    private(set) var decisionCode: String?
    var rejectDecision = false

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url!.path
        lock.withLock { paths.append(path) }
        let body = request.httpBody ?? Data()

        func reply(_ status: Int, _ json: String) -> (Data, HTTPURLResponse) {
            (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
        }

        switch path {
        case "/.well-known/t3/environment":
            return reply(200, #"{"environmentId":"env-1","label":"Test Mac","serverVersion":"0.1.9","orchestrationProtocolVersion":2}"#)
        case "/oauth/mcp/register":
            return reply(201, #"{"client_id":"client-1","redirect_uris":["http://127.0.0.1/tea-three/callback"]}"#)
        case "/oauth/mcp/decision":
            if rejectDecision { return reply(400, #"{"error":"invalid_grant","error_description":"pairing code expired"}"#) }
            let json = try JSONDecoder().decode(JSONValue.self, from: body)
            let state = json["authorization"]?["state"]?.stringValue ?? ""
            lock.withLock {
                challenge = json["authorization"]?["code_challenge"]?.stringValue
                decisionCode = json["decision"]?["code"]?.stringValue
            }
            return reply(200, #"{"redirectTo":"http://127.0.0.1/tea-three/callback?code=auth-code&state=\#(state)&iss=x"}"#)
        case "/oauth/mcp/token":
            let form = URLComponents(string: "?\(String(decoding: body, as: UTF8.self))")?.queryItems ?? []
            let verifier = form.first { $0.name == "code_verifier" }?.value ?? ""
            let expected = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
            lock.withLock { verifiedPKCE = expected == challenge && form.first { $0.name == "code" }?.value == "auth-code" }
            return reply(200, #"{"access_token":"issued-token","token_type":"Bearer","expires_in":2592000,"scope":"orchestration:read orchestration:operate"}"#)
        default:
            return reply(404, "{}")
        }
    }
}
