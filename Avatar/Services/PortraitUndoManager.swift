import Foundation
import SwiftData

/// Captures a full snapshot of all undoable portrait properties so that
/// any single edit (drag, scale, adjustment slider, background change, etc.)
/// can be reverted with ⌘Z and re-applied with ⌘⇧Z.
///
/// Usage:
///   1. Call `beginChange(for:undoManager:actionName:)` **before** mutating.
///   2. Mutate the portrait properties + call `context.save()`.
///   The undo step is registered automatically.
@MainActor
enum PortraitUndoManager {

    // MARK: - Snapshot

    struct Snapshot {
        let id: UUID
        // Transform
        let offsetX: Double
        let offsetY: Double
        let scale: Double
        // Background
        let backgroundPresetID: UUID?
        // Adjustments
        let adjExposure: Double
        let adjContrast: Double
        let adjBrightness: Double
        let adjSaturation: Double
        let adjHue: Double
        let adjTemperature: Double
        let adjTint: Double
        let adjHighlights: Double
        let adjShadows: Double
        let adjWhites: Double
        let adjBlacks: Double
        // Metadata
        let name: String
        let tags: String
        let updatedAt: Date
    }

    static func snapshot(of p: Portrait) -> Snapshot {
        Snapshot(
            id: p.id,
            offsetX: p.offsetX,
            offsetY: p.offsetY,
            scale: p.scale,
            backgroundPresetID: p.backgroundPresetID,
            adjExposure: p.adjExposure,
            adjContrast: p.adjContrast,
            adjBrightness: p.adjBrightness,
            adjSaturation: p.adjSaturation,
            adjHue: p.adjHue,
            adjTemperature: p.adjTemperature,
            adjTint: p.adjTint,
            adjHighlights: p.adjHighlights,
            adjShadows: p.adjShadows,
            adjWhites: p.adjWhites,
            adjBlacks: p.adjBlacks,
            name: p.name,
            tags: p.tags,
            updatedAt: p.updatedAt
        )
    }

    // MARK: - Public API

    /// Take a snapshot of the current state. Call this **before** you change
    /// anything. After you mutate the portrait and save, the undo step is
    /// registered automatically from the captured "before" state.
    static func beginChange(
        for portrait: Portrait,
        context: ModelContext,
        undoManager: UndoManager?,
        appState: AppState? = nil,
        actionName: String
    ) {
        let before = snapshot(of: portrait)
        // Defer registration to the next run-loop tick so the caller can
        // finish mutating the portrait first. The "after" snapshot is taken
        // at that point.
        DispatchQueue.main.async {
            let after = snapshot(of: portrait)
            registerUndo(
                before: before,
                after: after,
                context: context,
                undoManager: undoManager,
                appState: appState,
                actionName: actionName
            )
        }
    }

    /// Register an undo step from explicit before/after snapshots.
    /// Use this when you manage the snapshot lifecycle yourself (e.g. drag
    /// gestures where the mutation spans many frames).
    static func registerFromSnapshots(
        before: Snapshot,
        after: Snapshot,
        context: ModelContext,
        undoManager: UndoManager?,
        appState: AppState? = nil,
        actionName: String
    ) {
        registerUndo(
            before: before,
            after: after,
            context: context,
            undoManager: undoManager,
            appState: appState,
            actionName: actionName
        )
    }

    // MARK: - Undo / Redo

    private static func registerUndo(
        before: Snapshot,
        after: Snapshot,
        context: ModelContext,
        undoManager: UndoManager?,
        appState: AppState?,
        actionName: String
    ) {
        guard let um = undoManager else { return }
        um.registerUndo(withTarget: context) { ctx in
            apply(before, in: ctx, appState: appState)
            try? ctx.save()
            // The reverse registration creates the redo action.
            registerUndo(
                before: after,
                after: before,
                context: ctx,
                undoManager: um,
                appState: appState,
                actionName: actionName
            )
        }
        um.setActionName(actionName)
    }

    private static func apply(_ snap: Snapshot, in context: ModelContext, appState: AppState?) {
        let id = snap.id
        let descriptor = FetchDescriptor<Portrait>(predicate: #Predicate { $0.id == id })
        guard let portrait = try? context.fetch(descriptor).first else { return }
        portrait.offsetX = snap.offsetX
        portrait.offsetY = snap.offsetY
        portrait.scale = snap.scale
        portrait.backgroundPresetID = snap.backgroundPresetID
        portrait.adjExposure = snap.adjExposure
        portrait.adjContrast = snap.adjContrast
        portrait.adjBrightness = snap.adjBrightness
        portrait.adjSaturation = snap.adjSaturation
        portrait.adjHue = snap.adjHue
        portrait.adjTemperature = snap.adjTemperature
        portrait.adjTint = snap.adjTint
        portrait.adjHighlights = snap.adjHighlights
        portrait.adjShadows = snap.adjShadows
        portrait.adjWhites = snap.adjWhites
        portrait.adjBlacks = snap.adjBlacks
        portrait.name = snap.name
        portrait.tags = snap.tags
        portrait.updatedAt = snap.updatedAt
        appState?.invalidateAdjusted(for: portrait)
    }
}
