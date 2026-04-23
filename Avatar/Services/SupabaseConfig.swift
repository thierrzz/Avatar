import Foundation

/// Static configuration for the Supabase-backed Pro stack.
/// URL and publishable key are safe to ship inside the client binary — the
/// publishable key is the read-only anon-equivalent under RLS, not a secret.
enum SupabaseConfig {
    static let url = URL(string: "https://acmnyvdzjxayynmtnsav.supabase.co")!
    static let publishableKey = "sb_publishable_eW5edOEumcjLO1l_4UFdgQ_cfau6krh"

    /// Custom URL scheme the OAuth provider redirects to once the user
    /// completes Google sign-in in the default browser.
    static let authRedirectURL = URL(string: "aaavatar://auth-callback")!
}
