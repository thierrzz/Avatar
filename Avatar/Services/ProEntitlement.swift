import Foundation

/// Pro subscription tier. Backend is source of truth — these raw values
/// match the `tier` column in Supabase.
enum ProTier: String, Codable, CaseIterable, Identifiable, Sendable {
    case starter, plus, studio

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .starter: return "Starter"
        case .plus:    return "Plus"
        case .studio:  return "Studio"
        }
    }

    /// Monthly credit grant, mirrored server-side.
    var monthlyCredits: Int {
        switch self {
        case .starter: return 20
        case .plus:    return 50
        case .studio:  return 150
        }
    }

    /// Display price in EUR (informational only — Stripe is source of truth).
    var monthlyPriceEUR: String {
        switch self {
        case .starter: return "€4,99"
        case .plus:    return "€9,99"
        case .studio:  return "€19,99"
        }
    }
}

/// Observable Pro/credits state. Populated by `BackendClient.me()` on launch,
/// after checkout return, and when a 402 is received from `/extend-body`.
@MainActor
@Observable
final class ProEntitlement {
    /// Active tier, or nil when the user has no subscription.
    var tier: ProTier?
    /// Credits remaining in the current billing period.
    var credits: Int = 0
    /// End of the current billing period (credits reset at this time).
    var renewsAt: Date?
    /// Whether a refresh request is in flight.
    var isRefreshing: Bool = false
    /// Last error message from a refresh attempt.
    var lastError: String?

    var isPro: Bool { tier != nil }
    var hasCredits: Bool { credits > 0 }

    /// Resets all state (e.g. on sign-out).
    func clear() {
        tier = nil
        credits = 0
        renewsAt = nil
        lastError = nil
    }

    /// Replace state from a server payload.
    func apply(_ payload: MePayload) {
        tier = payload.tier
        credits = payload.credits
        renewsAt = payload.renewsAt
        lastError = nil
    }
}

/// Server payload for `GET /api/me`.
struct MePayload: Codable, Sendable {
    let tier: ProTier?
    let credits: Int
    let renewsAt: Date?
}
