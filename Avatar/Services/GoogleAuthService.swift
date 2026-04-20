import Foundation
import GoogleSignIn
import AppKit

/// Manages Google Sign-In for workspace functionality.
/// Uses the `drive.file` scope — the app can only access files it created
/// or files explicitly shared with it, not the user's entire Drive.
@MainActor
@Observable
final class GoogleAuthService {

    private(set) var currentUser: GIDGoogleUser?
    private(set) var isSignedIn = false
    private(set) var isSigningIn = false
    private(set) var lastError: String?

    /// The OAuth client ID from Google Cloud Console.
    /// In production, this should come from a config file or environment.
    /// The user must create a project at https://console.cloud.google.com
    /// and enable the Google Drive API.
    static let clientID = "352886726285-hb27mhp83uujlbvufjscauet7ir2gehr.apps.googleusercontent.com"

    /// Required OAuth scopes — `drive.file` is the minimal scope that allows
    /// creating, reading, and writing files the app owns.
    private static let scopes = ["https://www.googleapis.com/auth/drive.file"]

    // MARK: - Lifecycle

    /// Attempts to restore a previous sign-in session silently.
    func restorePreviousSignIn() {
        GIDSignIn.sharedInstance.restorePreviousSignIn { [weak self] user, error in
            Task { @MainActor in
                guard let self else { return }
                if let user {
                    self.currentUser = user
                    self.isSignedIn = true
                } else if let error {
                    print("[GoogleAuth] restore failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Initiates the Google Sign-In flow using the app's main window.
    func signIn() {
        guard !isSigningIn else { return }
        isSigningIn = true
        lastError = nil

        guard let window = NSApp.keyWindow else {
            lastError = "No window available for sign-in."
            isSigningIn = false
            return
        }

        let config = GIDConfiguration(clientID: Self.clientID)
        GIDSignIn.sharedInstance.configuration = config

        GIDSignIn.sharedInstance.signIn(
            withPresenting: window,
            hint: nil,
            additionalScopes: Self.scopes
        ) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                self.isSigningIn = false

                if let error {
                    // Don't show error if user cancelled
                    if (error as NSError).code != GIDSignInError.canceled.rawValue {
                        self.lastError = error.localizedDescription
                    }
                    return
                }

                guard let user = result?.user else {
                    self.lastError = "Sign-in completed but no user returned."
                    return
                }

                self.currentUser = user
                self.isSignedIn = true
                print("[GoogleAuth] signed in as \(user.profile?.email ?? "unknown")")
            }
        }
    }

    /// Signs out and clears the cached user.
    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        currentUser = nil
        isSignedIn = false
        lastError = nil
    }

    // MARK: - Token access

    /// Returns a valid access token, refreshing if necessary.
    /// Call this before every Drive API request.
    func validAccessToken() async throws -> String {
        guard let user = currentUser else {
            throw GoogleAuthError.notSignedIn
        }

        // Check if the token needs refreshing (< 60 seconds remaining)
        if let expiry = user.accessToken.expirationDate, expiry.timeIntervalSinceNow < 60 {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                user.refreshTokensIfNeeded { _, error in
                    if let error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume()
                    }
                }
            }
        }

        return user.accessToken.tokenString
    }

    // MARK: - User info

    var userEmail: String? { currentUser?.profile?.email }
    var userName: String? { currentUser?.profile?.name }
    var userAvatarURL: URL? { currentUser?.profile?.imageURL(withDimension: 64) }
}

enum GoogleAuthError: LocalizedError {
    case notSignedIn

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Not signed in to Google."
        }
    }
}
