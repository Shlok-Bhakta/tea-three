import Foundation

/// Whether the T3 Code server can be reached right now, for the status light.
public enum ConnectionStatus: Sendable, Equatable {
    case connected(latency: TimeInterval)
    /// No answer, or not a T3 Code server answering (VPN off, no internet, server down).
    case unreachable(String)
    /// The server is there but the saved login isn't usable.
    case signedOut(String)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

extension TeaThreeService {
    /// A cheap reachability check: the unauthenticated environment descriptor,
    /// with a short timeout so a dead VPN shows up in seconds, not a minute.
    public func checkConnection(timeout: TimeInterval = 5) async -> ConnectionStatus {
        guard let credential = credentials.load() else { return .signedOut("Not paired") }
        if credential.isExpired { return .signedOut("Login expired") }
        let url = credential.serverURL.appendingPathComponent(".well-known/t3/environment")
        let started = Date()
        do {
            let (data, response) = try await transport.send(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout))
            guard response.statusCode == 200, (try? JSONDecoder().decode(T3Environment.self, from: data)) != nil else {
                return .unreachable("Answered HTTP \(response.statusCode)")
            }
            return .connected(latency: Date().timeIntervalSince(started))
        } catch let error as URLError {
            return .unreachable(Self.describe(error))
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    public static func describe(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet, .dataNotAllowed: "No internet connection"
        case .timedOut: "No answer (timed out)"
        case .cannotConnectToHost, .networkConnectionLost: "Server isn't answering"
        case .cannotFindHost, .dnsLookupFailed: "Can't find the server"
        default: error.localizedDescription
        }
    }
}
