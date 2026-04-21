import Foundation
import AppKit
import Supabase
import Auth

/// Thin wrapper around `SupabaseClient.auth`. Owns the single `SupabaseClient`
/// used by the app, exposes a minimal, observable surface for views, and
/// keeps the synchronous `accessToken` / `email` / `isSignedIn` fields that
/// `BackendClient` and the Settings UI read. Sessions persist in the system
/// Keychain via `KeychainLocalStorage` (SDK default on Apple platforms).
@MainActor
@Observable
final class AuthManager {
    /// Current Supabase access token (JWT) or nil when signed out.
    private(set) var accessToken: String?
    /// Display identity for the Settings UI.
    private(set) var email: String?
    /// True while an OAuth round-trip is in flight.
    var isSigningIn: Bool = false

    var isSignedIn: Bool { accessToken != nil }

    /// The shared Supabase client. Exposed so other services (e.g. the
    /// BackendClient fallback paths, or future realtime features) can reuse
    /// the same session store instead of instantiating their own.
    @ObservationIgnored
    let supabase: SupabaseClient

    @ObservationIgnored
    private var authStateTask: Task<Void, Never>?

    init() {
        self.supabase = SupabaseClient(
            supabaseURL: SupabaseConfig.url,
            supabaseKey: SupabaseConfig.publishableKey,
        )
        observeAuthState()
    }

    deinit {
        authStateTask?.cancel()
    }

    /// Opens Google OAuth in the user's default browser. The browser will
    /// redirect back to `aaavatar://auth-callback?...` which the URL scheme
    /// handler forwards to `completeSignIn(from:)`.
    func startSignIn() {
        isSigningIn = true
        do {
            let url = try supabase.auth.getOAuthSignInURL(
                provider: .google,
                redirectTo: SupabaseConfig.authRedirectURL,
            )
            NSWorkspace.shared.open(url)
        } catch {
            isSigningIn = false
        }
    }

    /// Called by the URL scheme handler when the browser returns with an
    /// OAuth code or fragment. Exchanges it for a session and persists it.
    func completeSignIn(from url: URL) async {
        defer { isSigningIn = false }
        do {
            _ = try await supabase.auth.session(from: url)
        } catch {
            // Session exchange failed — leave state signed-out. The SDK
            // keeps logs; surfacing the error to the UI is the caller's job.
        }
    }

    func signOut() {
        Task {
            try? await supabase.auth.signOut()
        }
    }

    // MARK: - Internal

    /// Subscribe to Supabase auth events so `accessToken` / `email` stay in
    /// sync across launches, token refreshes, and sign-outs.
    private func observeAuthState() {
        authStateTask = Task { [weak self] in
            guard let self else { return }
            for await (_, session) in self.supabase.auth.authStateChanges {
                await MainActor.run {
                    self.accessToken = session?.accessToken
                    self.email = session?.user.email
                }
            }
        }
    }
}
