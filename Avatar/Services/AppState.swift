import Foundation
import SwiftUI
import SwiftData

enum SettingsTab: String {
    case backgrounds, exportPresets, aiModel, updates, language
}

@MainActor
@Observable
final class AppState {
    /// The set of currently selected portrait IDs (supports multi-select).
    var selectedPortraitIDs: Set<UUID> = []

    /// Convenience for single-selection. Returns the ID only when exactly one
    /// portrait is selected; setting it replaces the entire selection.
    var selectedPortraitID: UUID? {
        get { selectedPortraitIDs.count == 1 ? selectedPortraitIDs.first : nil }
        set {
            if let id = newValue { selectedPortraitIDs = [id] }
            else { selectedPortraitIDs.removeAll() }
        }
    }

    var isBatchSelected: Bool { selectedPortraitIDs.count > 1 }

    var isImporting = false
    var isProcessing = false
    var lastError: String?

    // MARK: - Batch progress

    var batchTotal: Int = 0
    var batchCompleted: Int = 0
    var batchErrors: [String] = []
    var isBatchCancelled = false

    var batchProgress: Double {
        batchTotal > 0 ? Double(batchCompleted) / Double(batchTotal) : 0
    }

    func resetBatchState() {
        batchTotal = 0
        batchCompleted = 0
        batchErrors = []
        isBatchCancelled = false
    }

    // MARK: - Workspace selection

    /// The currently selected workspace. `nil` means "My Library" (all local portraits).
    /// Persisted in UserDefaults so the selection survives app restarts.
    var selectedWorkspaceID: UUID? = UserDefaults.standard.string(forKey: "selectedWorkspaceID")
        .flatMap({ UUID(uuidString: $0) }) {
        didSet {
            if let id = selectedWorkspaceID {
                UserDefaults.standard.set(id.uuidString, forKey: "selectedWorkspaceID")
            } else {
                UserDefaults.standard.removeObject(forKey: "selectedWorkspaceID")
            }
        }
    }

    var isViewingWorkspace: Bool { selectedWorkspaceID != nil }

    /// When set, the main window presents the library import sheet for this URL.
    var libraryImportURL: URL?

    /// Which tab to select when the Settings window opens.
    var selectedSettingsTab: SettingsTab = .backgrounds

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
