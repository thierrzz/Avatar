import Foundation
import SwiftData
import CoreML

/// Adjustment deltas applied on top of each portrait's current values.
/// All fields start at 0 (no change). Additive for zero-neutral parameters,
/// additive for 1-neutral parameters (the BatchEditorView shows the delta,
/// not the absolute value).
struct BatchAdjustmentDeltas {
    var exposure: Double = 0        // add to adjExposure
    var contrast: Double = 0        // add to adjContrast
    var saturation: Double = 0      // add to adjSaturation
    var temperature: Double = 0     // add to adjTemperature
    var tint: Double = 0            // add to adjTint
    var highlights: Double = 0      // add to adjHighlights
    var shadows: Double = 0         // add to adjShadows

    var isZero: Bool {
        exposure == 0 && contrast == 0 && saturation == 0
            && temperature == 0 && tint == 0
            && highlights == 0 && shadows == 0
    }
}

/// Batch operations that act on multiple portraits at once.
/// All methods are @MainActor because they read/write SwiftData models.
@MainActor
enum BatchOperations {

    // MARK: - Background

    static func setBackground(
        portraits: [Portrait],
        presetID: UUID?,
        context: ModelContext,
        undoManager: UndoManager?,
        appState: AppState
    ) {
        let befores = portraits.map { PortraitUndoManager.snapshot(of: $0) }
        let now = Date()
        for p in portraits {
            p.backgroundPresetID = presetID
            p.updatedAt = now
        }
        try? context.save()
        let afters = portraits.map { PortraitUndoManager.snapshot(of: $0) }
        registerBatchUndo(befores: befores, afters: afters, context: context,
                          undoManager: undoManager, appState: appState,
                          actionName: Loc.batchSetBackground)
    }

    // MARK: - Adjustments (deltas)

    static func applyAdjustments(
        portraits: [Portrait],
        deltas: BatchAdjustmentDeltas,
        context: ModelContext,
        undoManager: UndoManager?,
        appState: AppState
    ) {
        guard !deltas.isZero else { return }
        let befores = portraits.map { PortraitUndoManager.snapshot(of: $0) }
        let now = Date()
        for p in portraits {
            p.adjExposure    = clamp(p.adjExposure    + deltas.exposure,    -2...2)
            p.adjContrast    = clamp(p.adjContrast    + deltas.contrast,    0.5...1.5)
            p.adjSaturation  = clamp(p.adjSaturation  + deltas.saturation,  0...2)
            p.adjTemperature = clamp(p.adjTemperature + deltas.temperature, -2000...2000)
            p.adjTint        = clamp(p.adjTint        + deltas.tint,        -100...100)
            p.adjHighlights  = clamp(p.adjHighlights  + deltas.highlights,  0...2)
            p.adjShadows     = clamp(p.adjShadows     + deltas.shadows,     -1...1)
            p.updatedAt = now
            appState.invalidateAdjusted(for: p)
        }
        try? context.save()
        let afters = portraits.map { PortraitUndoManager.snapshot(of: $0) }
        registerBatchUndo(befores: befores, afters: afters, context: context,
                          undoManager: undoManager, appState: appState,
                          actionName: Loc.batchApplyAdjustments)
    }

    static func resetAdjustments(
        portraits: [Portrait],
        context: ModelContext,
        undoManager: UndoManager?,
        appState: AppState
    ) {
        let befores = portraits.map { PortraitUndoManager.snapshot(of: $0) }
        let now = Date()
        for p in portraits {
            p.adjExposure = 0
            p.adjContrast = 1
            p.adjSaturation = 1
            p.adjTemperature = 0
            p.adjTint = 0
            p.adjHighlights = 1
            p.adjShadows = 0
            p.adjWhites = 0
            p.adjBlacks = 0
            p.adjBrightness = 0
            p.adjHue = 0
            p.updatedAt = now
            appState.invalidateAdjusted(for: p)
        }
        try? context.save()
        let afters = portraits.map { PortraitUndoManager.snapshot(of: $0) }
        registerBatchUndo(befores: befores, afters: afters, context: context,
                          undoManager: undoManager, appState: appState,
                          actionName: Loc.batchResetAdjustments)
    }

    // MARK: - Auto-Align

    static func autoAlign(
        portraits: [Portrait],
        context: ModelContext,
        undoManager: UndoManager?,
        appState: AppState
    ) -> BulkAligner.Result {
        BulkAligner.alignAll(portraits: portraits, appState: appState,
                             context: context, undoManager: undoManager)
    }

    // MARK: - Magic Retouch (async, sequential)

    static func magicRetouch(
        portraits: [Portrait],
        context: ModelContext,
        appState: AppState,
        modelManager: ModelManager? = nil
    ) {
        let eligible = portraits.filter { !$0.isMagicRetouched }
        guard !eligible.isEmpty else { return }

        appState.isProcessing = true
        appState.resetBatchState()
        appState.batchTotal = eligible.count

        // Process sequentially to limit memory usage.
        let ids = eligible.map(\.id)
        let birefnet: MLModel? = (modelManager?.useAdvancedModel == true) ? modelManager?.loadModel() : nil

        Task.detached(priority: .userInitiated) {
            for id in ids {
                let cancelled = await MainActor.run { appState.isBatchCancelled }
                if cancelled { break }

                await MainActor.run {
                    let descriptor = FetchDescriptor<Portrait>(predicate: #Predicate { $0.id == id })
                    guard let portrait = try? context.fetch(descriptor).first else {
                        appState.batchCompleted += 1
                        return
                    }
                    // Re-use existing single-portrait flow (it sets isProcessing itself,
                    // so we temporarily disable that).
                    ImportFlow.magicRetouch(portrait: portrait, context: context,
                                           appState: appState, modelManager: modelManager)
                }

                // Wait for the single-item processing to finish.
                while await MainActor.run(body: { appState.isProcessing && !appState.isBatchCancelled }) {
                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                }

                await MainActor.run {
                    appState.batchCompleted += 1
                    appState.isProcessing = true // keep batch going
                }
            }

            await MainActor.run {
                appState.isProcessing = false
            }
        }
    }

    static func undoMagicRetouch(
        portraits: [Portrait],
        context: ModelContext,
        appState: AppState
    ) {
        let eligible = portraits.filter(\.isMagicRetouched)
        for p in eligible {
            ImportFlow.undoMagicRetouch(portrait: p, context: context, appState: appState)
        }
    }

    // MARK: - Upscale (async, sequential)

    static func upscale(
        portraits: [Portrait],
        context: ModelContext,
        appState: AppState,
        modelManager: ModelManager? = nil
    ) {
        let eligible = portraits.filter { !$0.isUpscaled }
        guard !eligible.isEmpty else { return }

        appState.isProcessing = true
        appState.resetBatchState()
        appState.batchTotal = eligible.count

        let ids = eligible.map(\.id)

        Task.detached(priority: .userInitiated) {
            for id in ids {
                let cancelled = await MainActor.run { appState.isBatchCancelled }
                if cancelled { break }

                await MainActor.run {
                    let descriptor = FetchDescriptor<Portrait>(predicate: #Predicate { $0.id == id })
                    guard let portrait = try? context.fetch(descriptor).first else {
                        appState.batchCompleted += 1
                        return
                    }
                    ImportFlow.upscale(portrait: portrait, context: context,
                                      appState: appState, modelManager: modelManager)
                }

                while await MainActor.run(body: { appState.isProcessing && !appState.isBatchCancelled }) {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }

                await MainActor.run {
                    appState.batchCompleted += 1
                    appState.isProcessing = true
                }
            }

            await MainActor.run {
                appState.isProcessing = false
            }
        }
    }

    // MARK: - Delete

    static func delete(
        portraits: [Portrait],
        context: ModelContext,
        appState: AppState
    ) {
        for p in portraits {
            appState.invalidateCutout(for: p)
            context.delete(p)
        }
        appState.selectedPortraitIDs.removeAll()
        try? context.save()
    }

    // MARK: - Batch Undo (snapshot-based)

    private static func registerBatchUndo(
        befores: [PortraitUndoManager.Snapshot],
        afters: [PortraitUndoManager.Snapshot],
        context: ModelContext,
        undoManager: UndoManager?,
        appState: AppState,
        actionName: String
    ) {
        guard let um = undoManager, !befores.isEmpty else { return }
        um.registerUndo(withTarget: context) { ctx in
            applySnapshots(befores, in: ctx, appState: appState)
            try? ctx.save()
            // Register redo.
            registerBatchUndo(befores: afters, afters: befores,
                              context: ctx, undoManager: um,
                              appState: appState, actionName: actionName)
        }
        um.setActionName(actionName)
    }

    private static func applySnapshots(
        _ snapshots: [PortraitUndoManager.Snapshot],
        in context: ModelContext,
        appState: AppState
    ) {
        for snap in snapshots {
            PortraitUndoManager.applySnapshot(snap, in: context, appState: appState)
        }
    }

    // MARK: - Helpers

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
