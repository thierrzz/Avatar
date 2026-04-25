import Foundation

/// Static configuration for the Supabase-backed Pro stack.
/// Values are loaded from build settings (xcconfig) for secrets management.
enum SupabaseConfig {
    static let url = URL(string: Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String
        ?? "https://acmnyvdzjxayynmtnsav.supabase.co")!
    static let publishableKey = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_PUBLISHABLE_KEY") as? String
        ?? "sb_publishable_eW5edOEumcjLO1l_4UFdgQ_cfau6krh"

    /// Custom URL scheme the OAuth provider redirects to once the user
    /// completes Google sign-in in the default browser.
    static let authRedirectURL = URL(string: "aaavatar://auth-callback")!
}
