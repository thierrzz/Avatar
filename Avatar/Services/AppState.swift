import Foundation
import SwiftUI
import SwiftData

enum SettingsTab: String {
    case backgrounds, exportPresets, aiModel, updates, language
}

@MainActor
@Observable
final class AppState {
    var selectedPortraitID: UUID?
    var isImporting = false
    var isProcessing = false
    var lastError: String?

    /// Which tab to select when the Settings window opens.
    var selectedSettingsTab: SettingsTab = .backgrounds

    // MARK: - Pro / Extend Body
    /// Supabase-backed auth facade. Also used by `BackendClient`.
    let auth: AuthManager = AuthManager()
    /// Pro tier + credits balance. Populated by `BackendClient.me()`.
    let proEntitlement: ProEntitlement = ProEntitlement()
    /// Controls the paywall sheet. Set to `true` to open `ProUpgradeSheet`.
    var showProUpgradeSheet: Bool = false
    /// Set when a feature requires sign-in and the user isn't signed in.
    var showSignInPrompt: Bool = false
    /// Backend REST client. Bound to the shared `AuthManager` so calls and
    /// sign-in flow see the same token storage.
    @ObservationIgnored
    private(set) lazy var backend: BackendClient = BackendClient(auth: auth)

    /// Fetches the latest entitlement from the backend. Silent on network
    /// errors — keeps whatever state was previously cached.
    func refreshEntitlement() {
        guard auth.isSignedIn else {
            proEntitlement.clear()
            return
        }
        proEntitlement.isRefreshing = true
        Task {
            do {
                let me = try await backend.me()
                proEntitlement.apply(me)
            } catch {
                proEntitlement.lastError = (error as? LocalizedError)?.errorDescription
            }
            proEntitlement.isRefreshing = false
        }
    }

    /// Display language. Changing this re-renders all views that read it,
    /// and `Loc` picks up the new value from UserDefaults.
    var language: Lang = Lang.current {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "appLanguage") }
    }

    /// In-memory cache of decoded cutout CGImages keyed by portrait id,
    /// so the editor doesn't re-decode on every redraw.
    private var cutoutCache: [UUID: CGImage] = [:]
    /// In-memory cache of the adjusted cutout (base cutout + CIFilter chain),
    /// keyed by portrait id. Stored with the adjustments' hash so we can
    /// invalidate as soon as any slider changes value.
    private var adjustedCutoutCache: [UUID: (key: Int, image: CGImage)] = [:]
    /// In-memory cache of decoded background images keyed by preset id.
    private var backgroundCache: [UUID: CGImage] = [:]

    func cutout(for portrait: Portrait) -> CGImage? {
        if let cached = cutoutCache[portrait.id] { return cached }
        guard let data = portrait.cutoutPNG,
              let img = ImageProcessor.cgImage(from: data) else { return nil }
        cutoutCache[portrait.id] = img
        return img
    }

    /// Returns the cutout with the portrait's current adjustments applied.
    /// Falls back to the raw cutout when adjustments are neutral (fast path)
    /// or when the CI filter chain fails to render.
    func adjustedCutout(for portrait: Portrait) -> CGImage? {
        guard let base = cutout(for: portrait) else { return nil }
        let adj = ImageAdjustments(from: portrait)
        if adj.isNeutral { return base }
        let key = adj.hashValue
        if let hit = adjustedCutoutCache[portrait.id], hit.key == key {
            return hit.image
        }
        guard let rendered = ImageAdjustmentRenderer.apply(adj, to: base) else {
            return base
        }
        adjustedCutoutCache[portrait.id] = (key, rendered)
        return rendered
    }

    func invalidateCutout(for portrait: Portrait) {
        cutoutCache.removeValue(forKey: portrait.id)
        adjustedCutoutCache.removeValue(forKey: portrait.id)
    }

    func invalidateAdjusted(for portrait: Portrait) {
        adjustedCutoutCache.removeValue(forKey: portrait.id)
    }

    func backgroundImage(for preset: BackgroundPreset) -> CGImage? {
        guard preset.kind == .image else { return nil }
        if let cached = backgroundCache[preset.id] { return cached }
        guard preset.modelContext != nil,
              let data = preset.imageData,
              let img = ImageProcessor.cgImage(from: data) else { return nil }
        backgroundCache[preset.id] = img
        return img
    }

    func invalidateBackground(_ preset: BackgroundPreset) {
        backgroundCache.removeValue(forKey: preset.id)
    }
}
