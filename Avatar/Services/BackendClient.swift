import Foundation

/// Typed errors the backend can return. `noCredits` (HTTP 402) triggers the
/// upgrade paywall; `unauthorized` (401) triggers sign-in.
enum BackendError: LocalizedError {
    case notSignedIn
    case unauthorized
    case noCredits
    case rateLimited
    case server(Int, String?)
    case decode
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:   return "Please sign in to continue."
        case .unauthorized:  return "Session expired. Please sign in again."
        case .noCredits:     return "You're out of credits for this period."
        case .rateLimited:   return "Too many requests. Please wait a moment."
        case .server(let s, let m): return m ?? "Server error (\(s))."
        case .decode:        return "Unexpected server response."
        case .transport(let e): return e.localizedDescription
        }
    }
}

/// REST client for the Avatar backend (Vercel + Supabase).
/// Production base URL: `https://api.aaavatar.nl`.
/// All requests authenticate via the Supabase JWT from `AuthManager`.
@MainActor
final class BackendClient {
    /// Override for local dev / staging.
    var baseURL: URL = URL(string: "https://avatars-api-five.vercel.app")!

    private unowned let auth: AuthManager
    private let session: URLSession

    init(auth: AuthManager, session: URLSession = .shared) {
        self.auth = auth
        self.session = session
    }

    // MARK: GET /api/me
    func me() async throws -> MePayload {
        try await request("/api/me", method: "GET")
    }

    // MARK: POST /api/checkout
    struct CheckoutResponse: Decodable { let url: String }
    func startCheckout(tier: ProTier) async throws -> URL {
        let body = try JSONEncoder().encode(["tier": tier.rawValue])
        let resp: CheckoutResponse = try await request("/api/checkout", method: "POST", body: body)
        guard let url = URL(string: resp.url) else { throw BackendError.decode }
        return url
    }

    // MARK: POST /api/portal
    func openPortal() async throws -> URL {
        let resp: CheckoutResponse = try await request("/api/portal", method: "POST")
        guard let url = URL(string: resp.url) else { throw BackendError.decode }
        return url
    }

    // MARK: POST /api/extend-body
    struct ExtendBodyResponse: Decodable { let imageBase64: String }
    func extendBody(cutoutPNG: Data) async throws -> Data {
        struct Body: Encodable { let cutoutPNGBase64: String }
        let body = try JSONEncoder().encode(Body(cutoutPNGBase64: cutoutPNG.base64EncodedString()))
        let resp: ExtendBodyResponse = try await request("/api/extend-body", method: "POST", body: body)
        guard let data = Data(base64Encoded: resp.imageBase64) else { throw BackendError.decode }
        return data
    }

    // MARK: - Generic request
    private func request<R: Decodable>(
        _ path: String,
        method: String,
        body: Data? = nil
    ) async throws -> R {
        guard let token = auth.accessToken else { throw BackendError.notSignedIn }

        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = body
        req.timeoutInterval = 120  // outpainting can take ~15-30s

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw BackendError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else { throw BackendError.decode }
        switch http.statusCode {
        case 200...299:
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            do {
                return try decoder.decode(R.self, from: data)
            } catch {
                throw BackendError.decode
            }
        case 401: throw BackendError.unauthorized
        case 402: throw BackendError.noCredits
        case 429: throw BackendError.rateLimited
        default:
            let msg = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw BackendError.server(http.statusCode, msg)
        }
    }
}
