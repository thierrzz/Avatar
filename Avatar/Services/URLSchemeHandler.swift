import Foundation
import AppKit

/// Dispatches `aaavatar://` URLs opened by the OS (typically via Stripe
/// Checkout return or Supabase OAuth return in the default browser).
///
/// Expected URL shapes:
///   `aaavatar://auth-callback#access_token=...&refresh_token=...`  (implicit)
///   `aaavatar://auth-callback?code=...`                             (PKCE)
///   `aaavatar://stripe-return?session_id=...`
///   `aaavatar://stripe-cancel`
@MainActor
enum URLSchemeHandler {
    static func handle(_ url: URL, appState: AppState) {
        guard url.scheme == "aaavatar" else { return }
        guard let host = url.host else { return }

        switch host {
        case "auth-callback":
            Task {
                await appState.auth.completeSignIn(from: url)
                appState.refreshEntitlement()
                NSApp.activate(ignoringOtherApps: true)
            }
        case "stripe-return":
            // Poll the backend for the webhook-updated state.
            appState.showProUpgradeSheet = false
            appState.refreshEntitlement()
            NSApp.activate(ignoringOtherApps: true)
        case "stripe-cancel":
            // User cancelled checkout — leave sheet open so they can retry.
            NSApp.activate(ignoringOtherApps: true)
        default:
            break
        }
    }
}
