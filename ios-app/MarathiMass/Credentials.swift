import Foundation

/// How the app authenticates to Azure Speech.
enum Credentials {
    case key(String, region: String)
    case token(String, region: String, refreshInSec: Int)

    var region: String {
        switch self {
        case .key(_, let r), .token(_, let r, _): return r
        }
    }

    /// Reads settings: a server URL wins over a pasted key.
    static func load(from settings: AppSettings) async throws -> Credentials {
        let url = settings.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.isEmpty {
            return try await fetchToken(server: url, pin: settings.serverPIN)
        }
        let key = settings.azureKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw CredentialError.notConfigured }
        return .key(key, region: settings.azureRegion.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private struct TokenResponse: Decodable {
        let token: String
        let region: String
        let refreshInSec: Int?
    }

    /// Calls GET {server}/api/token on the companion Node server.
    private static func fetchToken(server: String, pin: String) async throws -> Credentials {
        var base = server
        if !base.hasPrefix("http") { base = "https://" + base }
        if base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/api/token") else { throw CredentialError.badServerURL }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 20
        if !pin.isEmpty { req.setValue(pin, forHTTPHeaderField: "X-App-Pin") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw CredentialError.badPIN }
        guard status == 200 else { throw CredentialError.server(status) }
        let t = try JSONDecoder().decode(TokenResponse.self, from: data)
        return .token(t.token, region: t.region, refreshInSec: t.refreshInSec ?? 480)
    }
}

enum CredentialError: LocalizedError {
    case notConfigured, badServerURL, badPIN, server(Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Open Settings (gear) and enter your Azure key and region, or a server address."
        case .badServerURL: return "The server address in Settings is not a valid URL."
        case .badPIN: return "Wrong access PIN. Open Settings (gear) and check it."
        case .server(let code): return "The token server answered with error \(code)."
        }
    }
}
