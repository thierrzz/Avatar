import Foundation
import AppKit

/// Minimal auth facade. Backend-agnostic API so the Supabase integration can
/// be swapped in later without touching call-sites. For now, tokens live in
/// UserDefaults with a TODO marker — a Keychain wrapper will replace this
/// before release (see plan §Deel 2, KeychainStore).
@MainActor
@Observable
final class AuthManager {
    /// Currently cached session JWT (Supabase `access_token`). Nil when signed out.
    private(set) var accessToken: String?
    /// Display identity for the Settings UI. Nil when signed out.
    private(set) var email: String?
    /// True while an OAuth round-trip is in flight.
    var isSigningIn: Bool = false

    private let tokenKey = "nl.aaavatar.session.accessToken"
    private let emailKey = "nl.aaavatar.session.email"

    var isSignedIn: Bool { accessToken != nil }

    init() {
        // Restore session from UserDefaults (TODO: migrate to Keychain before launch).
        self.accessToken = UserDefaults.standard.string(forKey: tokenKey)
        self.email = UserDefaults.standard.string(forKey: emailKey)
    }

    /// Kicks off Supabase Google OAuth in the default browser.
    /// Return URL `aaavatar://auth-callback?access_token=...` is handled by
    /// `URLSchemeHandler.handleAuthCallback(_:)`.
    func startSignIn() {
        isSigningIn = true
        // TODO: wire to Supabase auth URL once backend env var is available.
        // Expected URL shape:
        //   https://<project>.supabase.co/auth/v1/authorize
        //     ?provider=google
        //     &redirect_to=aaavatar://auth-callback
        if let url = URL(string: "https://aaavatar.nl/pro?source=app") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Called by the URL scheme handler when the browser returns with tokens.
    func completeSignIn(accessToken: String, email: String?) {
        self.accessToken = accessToken
        self.email = email
        UserDefaults.standard.set(accessToken, forKey: tokenKey)
        if let email { UserDefaults.standard.set(email, forKey: emailKey) }
        isSigningIn = false
    }

    func signOut() {
        accessToken = nil
        email = nil
        UserDefaults.standard.removeObject(forKey: tokenKey)
        UserDefaults.standard.removeObject(forKey: emailKey)
    }
}
