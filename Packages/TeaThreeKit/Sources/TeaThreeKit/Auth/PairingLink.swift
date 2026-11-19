import Foundation

/// What the user gives us to pair: a server and a one-time pairing code.
///
/// Accepts everything `t3 pair` prints:
/// - `http://192.168.1.5:3773/pair#token=K7Q2M9XRT4ZP` (the QR code)
/// - `t3code://pair?pairingUrl=<url-encoded pairing URL>` (the app link)
/// - `teathree://pair?pairingUrl=...` (our own scheme, same shape)
/// - a bare server URL plus a separately typed code
public struct PairingLink: Sendable, Equatable {
    public let serverURL: URL
    public let code: String

    public init(server: String, code: String) throws {
        try self.init(serverURL: Self.normalizeServer(server), code: code)
    }

    public init(serverURL: URL, code: String) throws {
        let normalized = code.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        // Older servers and `AUTO-` approval codes may not match the alphabet;
        // only reject what can't possibly be a code.
        guard normalized.count >= 6 else {
            throw T3Error.pairing("That pairing code looks too short.")
        }
        self.serverURL = try Self.normalizeServer(serverURL)
        self.code = normalized
    }

    public static func parse(_ input: String) throws -> PairingLink {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased() else {
            throw T3Error.pairing("That doesn't look like a pairing link.")
        }

        if scheme.hasPrefix("t3code") || scheme == "teathree" {
            guard let inner = components.queryItems?.first(where: { $0.name == "pairingUrl" })?.value else {
                throw T3Error.pairing("The app link is missing its pairing URL.")
            }
            return try parse(inner)
        }

        guard scheme == "http" || scheme == "https" else {
            throw T3Error.pairing("Unsupported link type \(scheme).")
        }

        let fragmentToken = components.fragment.flatMap { fragment in
            URLComponents(string: "?\(fragment)")?.queryItems?.first(where: { $0.name == "token" })?.value
        }
        let queryToken = components.queryItems?.first(where: { $0.name == "token" })?.value
        guard let code = fragmentToken ?? queryToken else {
            throw T3Error.pairing("That link has no pairing code. Run `t3 pair` on your Mac.")
        }

        // Hosted pairing links carry the real backend in `?host=`.
        if let host = components.queryItems?.first(where: { $0.name == "host" })?.value, let hostURL = URL(string: host) {
            return try PairingLink(serverURL: hostURL, code: code)
        }

        components.path = components.path.hasSuffix("/pair") ? String(components.path.dropLast(5)) : components.path
        components.fragment = nil
        components.query = nil
        guard let server = components.url else { throw T3Error.pairing("Couldn't read the server address.") }
        return try PairingLink(serverURL: server, code: code)
    }

    /// Adds a scheme when the user typed `192.168.1.5:3773` and strips trailing slashes.
    public static func normalizeServer(_ url: URL) throws -> URL {
        try normalizeServer(url.absoluteString)
    }

    /// Typed input: `URL(string:)` can't even parse `100.64.0.7:3773`.
    public static func normalizeServer(_ input: String) throws -> URL {
        var string = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !string.contains("://") {
            // IP literals are almost always plain HTTP on the LAN/tailnet; names
            // (like *.ts.net) almost always HTTPS. Same rule as the official app.
            let host = string.split(separator: ":").first.map(String.init) ?? string
            let isIP = host.allSatisfy { $0.isNumber || $0 == "." } || host == "localhost"
            string = (isIP ? "http://" : "https://") + string
        }
        while string.hasSuffix("/") { string.removeLast() }
        guard let normalized = URL(string: string), normalized.host != nil else {
            throw T3Error.pairing("Couldn't read the server address.")
        }
        return normalized
    }
}
