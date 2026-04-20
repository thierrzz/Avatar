import Foundation
import SwiftData
import AppKit
import UniformTypeIdentifiers
import CoreML

/// Thread-safe collector that gathers image data from multiple NSItemProviders.
/// All loads MUST be kicked off synchronously (before the drop handler returns)
/// so the system keeps the providers alive. The `onComplete` callback fires on
/// the main queue once every provider has reported.
private final class DropDataCollector: @unchecked Sendable {
    struct Item: Sendable { let data: Data; let name: String }
    private var items: [Item] = []
    private let lock = NSLock()
    private var remaining: Int
    private let onComplete: @Sendable ([Item]) -> Void

    init(count: Int, onComplete: @escaping @Sendable ([Item]) -> Void) {
        self.remaining = count
        self.onComplete = onComplete
    }

    func report(_ item: Item?) {
        lock.lock()
        if let item { items.append(item) }
        remaining -= 1
        let done = remaining <= 0
        let result = done ? items : nil
        lock.unlock()
        if let result { onComplete(result) }
    }
}

/// Centralised drop-handler used by every view that should accept a portrait
/// drag-and-drop (the empty-state import zone AND the editor surface, so users
/// can drop a fresh photo at any time without going back to an empty state).
@MainActor
enum PortraitDropHandler {
    static func handle(providers: [NSItemProvider],
                       context: ModelContext,
                       appState: AppState,
                       modelManager: ModelManager? = nil) -> Bool {
        guard !providers.isEmpty else { return false }

        let fileURLType = UTType.fileURL.identifier
        let imageType = UTType.image.identifier

        // Show feedback immediately — the loaders below are async.
        appState.isProcessing = true

        // Single provider → original fast path (unchanged, proven to work).
        if providers.count == 1, let provider = providers.first {
            if provider.hasItemConformingToTypeIdentifier(fileURLType) {
                provider.loadDataRepresentation(forTypeIdentifier: fileURLType) { data, _ in
                    guard let data,
                          let urlString = String(data: data, encoding: .utf8),
                          let url = URL(string: urlString) ?? URL(dataRepresentation: data, relativeTo: nil)
                    else {
                        Task { @MainActor in
                            appState.isProcessing = false
                            appState.lastError = Loc.dropPhotoNotFound
                        }
                        return
                    }
                    Task { @MainActor in
                        if url.pathExtension.lowercased() == "avatarlib" {
                            appState.isProcessing = false
                            appState.libraryImportURL = url
                            return
                        }
                        ImportFlow.importFile(url: url, context: context, appState: appState,
                                             modelManager: modelManager)
                    }
                }
                return true
            }
            if provider.hasItemConformingToTypeIdentifier(imageType) {
                provider.loadDataRepresentation(forTypeIdentifier: imageType) { data, _ in
                    guard let data else {
                        Task { @MainActor in
                            appState.isProcessing = false
                            appState.lastError = Loc.dropImageUnreadable
                        }
                        return
                    }
                    Task { @MainActor in
                        ImportFlow.importData(data, suggestedName: Loc.imported,
                                              context: context, appState: appState,
                                              modelManager: modelManager)
                    }
                }
                return true
            }
            appState.isProcessing = false
            appState.lastError = Loc.unknownFileType
            return false
        }

        // Multiple providers → read raw image DATA from each provider (not URLs).
        // This bypasses all security-scoped / sandbox issues since the system
        // copies the bytes for us.
        let eligible = providers.filter {
            $0.hasItemConformingToTypeIdentifier(fileURLType)
                || $0.hasItemConformingToTypeIdentifier(imageType)
        }
        guard !eligible.isEmpty else {
            appState.isProcessing = false
            appState.lastError = Loc.unknownFileType
            return false
        }

        print("[Drop] batch: \(eligible.count) providers")

        let collector = DropDataCollector(count: eligible.count) { items in
            DispatchQueue.main.async {
                guard !items.isEmpty else {
                    appState.isProcessing = false
                    appState.lastError = Loc.dropPhotoNotFound
                    print("[Drop] batch: all providers failed to load data")
                    return
                }
                print("[Drop] batch: collected \(items.count) items, starting import")
                ImportFlow.importDataBatch(items: items.map { ($0.data, $0.name) },
                                           context: context, appState: appState,
                                           modelManager: modelManager)
            }
        }

        for provider in eligible {
            // Try to extract the filename from the file URL type first.
            let suggestedName = provider.suggestedName ?? Loc.imported

            // Prefer loading as image data — works regardless of sandbox.
            let loadType = provider.hasItemConformingToTypeIdentifier(imageType) ? imageType : fileURLType
            provider.loadDataRepresentation(forTypeIdentifier: loadType) { data, error in
                if let data, !data.isEmpty {
                    collector.report(.init(data: data, name: suggestedName))
                } else {
                    print("[Drop] batch: provider failed: \(error?.localizedDescription ?? "no data")")
                    collector.report(nil)
                }
            }
        }

        return true
    }
}

@MainActor
enum ImportFlow {
    /// Reads a portrait file from disk, runs subject-lift + face detection,
    /// computes auto-alignment, and inserts a new Portrait into SwiftData.
    static func importFile(url: URL, context: ModelContext, appState: AppState,
                           modelManager: ModelManager? = nil) {
        // Set processing state IMMEDIATELY so the user sees feedback while the
        // file is being read and Vision is warming up.
        appState.isProcessing = true
        appState.lastError = nil

        print("[Import] start url=\(url.path)")

        // Sandboxed drag-and-drop URLs require explicit security-scope access.
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            appState.lastError = Loc.cannotReadFile(error.localizedDescription)
            appState.isProcessing = false
            print("[Import] FAILED Data(contentsOf:) error=\(error)")
            return
        }
        print("[Import] read bytes=\(data.count)")

        guard let cg = ImageProcessor.cgImage(from: data) else {
            appState.lastError = Loc.cannotDecodeImage
            appState.isProcessing = false
            print("[Import] FAILED CGImage decode (data was \(data.count) bytes)")
            return
        }
        print("[Import] loaded CGImage \(cg.width)x\(cg.height)")
        let suggestedName = url.deletingPathExtension().lastPathComponent

        let birefnet = (modelManager?.useAdvancedModel == true) ? modelManager?.loadModel() : nil
        runPipeline(cg: cg, originalData: data, suggestedName: suggestedName,
                    context: context, appState: appState, birefnetModel: birefnet)
    }

    // MARK: - Batch Import

    /// Imports multiple image files in one go, processing them sequentially to
    /// avoid memory pressure. Updates `batchCompleted` / `batchTotal` on
    /// `appState` so the UI can show a determinate progress bar. After
    /// completion the newly created portraits are auto-selected.
    static func importFiles(urls: [URL], context: ModelContext, appState: AppState,
                            modelManager: ModelManager? = nil) {
        guard !urls.isEmpty else { return }
        appState.isProcessing = true
        appState.lastError = nil
        appState.resetBatchState()
        appState.batchTotal = urls.count

        let birefnet = (modelManager?.useAdvancedModel == true) ? modelManager?.loadModel() : nil

        // Read file data on main thread (security-scoped access required).
        struct FileItem { let data: Data; let name: String }
        var items: [FileItem] = []
        for url in urls {
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                appState.batchCompleted += 1
                appState.batchErrors.append(Loc.cannotReadFile(url.lastPathComponent))
                continue
            }
            items.append(FileItem(data: data, name: url.deletingPathExtension().lastPathComponent))
        }

        Task.detached(priority: .userInitiated) {
            var newIDs: [UUID] = []

            for item in items {
                // Check cancellation.
                let cancelled = await MainActor.run { appState.isBatchCancelled }
                if cancelled { break }

                do {
                    guard let cg = ImageProcessor.cgImage(from: item.data) else {
                        await MainActor.run {
                            appState.batchCompleted += 1
                            appState.batchErrors.append("\(item.name): \(Loc.cannotDecodeImage)")
                        }
                        continue
                    }

                    let processed = try ImageProcessor.process(image: cg, birefnetModel: birefnet)
                    let cutoutSize = CGSize(width: processed.cutout.width, height: processed.cutout.height)
                    let face = processed.faceRect ?? .zero
                    let bodyBottom = processed.bodyBottomY
                    let transform = (processed.faceRect != nil)
                        ? AutoAligner.computeTransform(
                            faceRect: face,
                            eyeCenter: processed.eyeCenter,
                            interEyeDistance: processed.interEyeDistance,
                            cutoutSize: cutoutSize,
                            bodyBottomY: bodyBottom)
                        : AutoAligner.fitTransform(cutoutSize: cutoutSize)

                    let pngData = ImageProcessor.pngData(from: processed.cutout) ?? Data()

                    let id = await MainActor.run { () -> UUID in
                        let portrait = Portrait(
                            name: item.name,
                            cutoutPNG: pngData,
                            originalImageData: item.data,
                            faceRect: face,
                            eyeCenter: processed.eyeCenter,
                            interEyeDistance: Double(processed.interEyeDistance ?? 0),
                            bodyBottomY: Double(bodyBottom),
                            offsetX: Double(transform.offset.width),
                            offsetY: Double(transform.offset.height),
                            scale: Double(transform.scale)
                        )
                        portrait.isAdvancedCutout = (birefnet != nil)
                        context.insert(portrait)
                        appState.batchCompleted += 1
                        return portrait.id
                    }
                    newIDs.append(id)
                } catch {
                    await MainActor.run {
                        appState.batchCompleted += 1
                        appState.batchErrors.append("\(item.name): \(error.localizedDescription)")
                    }
                }
            }

            await MainActor.run {
                try? context.save()
                // Auto-select all newly imported portraits.
                appState.selectedPortraitIDs = Set(newIDs)
                appState.isProcessing = false
                if !appState.batchErrors.isEmpty {
                    appState.lastError = Loc.batchImportErrors(
                        succeeded: newIDs.count,
                        failed: appState.batchErrors.count)
                }
                print("[BatchImport] DONE imported=\(newIDs.count) errors=\(appState.batchErrors.count)")
            }
        }
    }

    /// Batch-imports multiple images from raw data (used by multi-provider drop).
    /// Works like `importFiles` but skips file I/O since bytes are already loaded.
    static func importDataBatch(items: [(Data, String)],
                                context: ModelContext, appState: AppState,
                                modelManager: ModelManager? = nil) {
        guard !items.isEmpty else {
            appState.isProcessing = false
            return
        }
        appState.lastError = nil
        appState.resetBatchState()
        appState.batchTotal = items.count

        let birefnet = (modelManager?.useAdvancedModel == true) ? modelManager?.loadModel() : nil

        Task.detached(priority: .userInitiated) {
            var newIDs: [UUID] = []

            for (data, name) in items {
                let cancelled = await MainActor.run { appState.isBatchCancelled }
                if cancelled { break }

                do {
                    guard let cg = ImageProcessor.cgImage(from: data) else {
                        await MainActor.run {
                            appState.batchCompleted += 1
                            appState.batchErrors.append("\(name): \(Loc.cannotDecodeImage)")
                        }
                        continue
                    }

                    let processed = try ImageProcessor.process(image: cg, birefnetModel: birefnet)
                    let cutoutSize = CGSize(width: processed.cutout.width, height: processed.cutout.height)
                    let face = processed.faceRect ?? .zero
                    let bodyBottom = processed.bodyBottomY
                    let transform = (processed.faceRect != nil)
                        ? AutoAligner.computeTransform(
                            faceRect: face,
                            eyeCenter: processed.eyeCenter,
                            interEyeDistance: processed.interEyeDistance,
                            cutoutSize: cutoutSize,
                            bodyBottomY: bodyBottom)
                        : AutoAligner.fitTransform(cutoutSize: cutoutSize)

                    let pngData = ImageProcessor.pngData(from: processed.cutout) ?? Data()

                    let id = await MainActor.run { () -> UUID in
                        let portrait = Portrait(
                            name: name,
                            cutoutPNG: pngData,
                            originalImageData: data,
                            faceRect: face,
                            eyeCenter: processed.eyeCenter,
                            interEyeDistance: Double(processed.interEyeDistance ?? 0),
                            bodyBottomY: Double(bodyBottom),
                            offsetX: Double(transform.offset.width),
                            offsetY: Double(transform.offset.height),
                            scale: Double(transform.scale)
                        )
                        portrait.isAdvancedCutout = (birefnet != nil)
                        context.insert(portrait)
                        appState.batchCompleted += 1
                        print("[BatchImport] done \(name) id=\(portrait.id)")
                        return portrait.id
                    }
                    newIDs.append(id)
                } catch {
                    await MainActor.run {
                        appState.batchCompleted += 1
                        appState.batchErrors.append("\(name): \(error.localizedDescription)")
                    }
                }
            }

            await MainActor.run {
                try? context.save()
                appState.selectedPortraitIDs = Set(newIDs)
                appState.isProcessing = false
                if !appState.batchErrors.isEmpty {
                    appState.lastError = Loc.batchImportErrors(
                        succeeded: newIDs.count,
                        failed: appState.batchErrors.count)
                }
                print("[BatchImport] DONE imported=\(newIDs.count) errors=\(appState.batchErrors.count)")
            }
        }
    }

    /// Variant for when raw image bytes are already in memory (e.g. dragged from
    /// another app, no file URL).
    static func importData(_ data: Data, suggestedName: String,
                           context: ModelContext, appState: AppState,
                           modelManager: ModelManager? = nil) {
        appState.isProcessing = true
        appState.lastError = nil
        print("[Import] start data bytes=\(data.count)")

        guard let cg = ImageProcessor.cgImage(from: data) else {
            appState.lastError = Loc.cannotDecodeImage
            appState.isProcessing = false
            print("[Import] FAILED CGImage decode from raw data")
            return
        }
        let birefnet = (modelManager?.useAdvancedModel == true) ? modelManager?.loadModel() : nil
        runPipeline(cg: cg, originalData: data, suggestedName: suggestedName,
                    context: context, appState: appState, birefnetModel: birefnet)
    }

    /// Re-runs the cutout pipeline on an existing portrait, overwriting the
    /// cached PNG + face rect but preserving the user's manual transform
    /// (offset/scale) and any other editor state. Used by the editor's
    /// "Opnieuw uitknippen" action so users can re-render a portrait after
    /// pipeline improvements without losing their framing.
    static func reprocess(portrait: Portrait, context: ModelContext, appState: AppState,
                          modelManager: ModelManager? = nil) {
        guard let data = portrait.originalImageData else {
            appState.lastError = Loc.noOriginalForRecutout
            return
        }
        guard let cg = ImageProcessor.cgImage(from: data) else {
            appState.lastError = Loc.cannotDecodeOriginal
            return
        }

        appState.isProcessing = true
        appState.lastError = nil
        print("[Reprocess] start id=\(portrait.id) \(cg.width)x\(cg.height)")

        // Load the advanced model on the main thread before dispatching.
        let birefnet = (modelManager?.useAdvancedModel == true) ? modelManager?.loadModel() : nil

        let portraitID = portrait.id
        Task.detached(priority: .userInitiated) {
            do {
                let processed = try ImageProcessor.process(image: cg, birefnetModel: birefnet)
                let pngData = ImageProcessor.pngData(from: processed.cutout) ?? Data()
                print("[Reprocess] done bytes=\(pngData.count) face=\(processed.faceRect ?? .zero)")

                await MainActor.run {
                    // Re-fetch the portrait on the main actor to avoid
                    // crossing isolation boundaries with the @Model object.
                    let descriptor = FetchDescriptor<Portrait>(
                        predicate: #Predicate { $0.id == portraitID }
                    )
                    guard let fresh = try? context.fetch(descriptor).first else {
                        appState.isProcessing = false
                        appState.lastError = Loc.portraitNotFound
                        return
                    }
                    fresh.cutoutPNG = pngData
                    fresh.faceRect = processed.faceRect ?? .zero
                    fresh.eyeCenter = processed.eyeCenter
                    fresh.interEyeDistance = Double(processed.interEyeDistance ?? 0)
                    fresh.bodyBottomY = Double(processed.bodyBottomY)
                    fresh.isMagicRetouched = false
                    fresh.preRetouchPNG = nil
                    fresh.isAdvancedCutout = (birefnet != nil)
                    fresh.didUpgradeCutout = false
                    fresh.preCutoutPNG = nil
                    fresh.updatedAt = Date()
                    try? context.save()
                    // Purge any cached decoded cutout so the editor shows the
                    // refreshed PNG on next access.
                    appState.invalidateCutout(for: fresh)
                    appState.isProcessing = false
                }
            } catch {
                await MainActor.run {
                    appState.lastError = Loc.recutoutFailed(error.localizedDescription)
                    appState.isProcessing = false
                    print("[Reprocess] ERROR \(error)")
                }
            }
        }
    }

    // MARK: - Upscale

    /// Upscales the portrait's original image by 2× using Lanczos interpolation,
    /// then re-runs the full cutout pipeline (subject lift + face detection +
    /// body pose) from the higher-resolution source. Updates `originalImageData`
    /// with the upscaled version and sets `isUpscaled = true`.
    /// Preserves the user's manual offset/scale transform.
    static func upscale(portrait: Portrait, context: ModelContext, appState: AppState,
                        modelManager: ModelManager? = nil) {
        guard !portrait.isUpscaled else {
            appState.lastError = Loc.alreadyUpscaled
            return
        }
        guard let data = portrait.originalImageData else {
            appState.lastError = Loc.noOriginalForUpscale
            return
        }
        guard let cg = ImageProcessor.cgImage(from: data) else {
            appState.lastError = Loc.cannotDecodeOriginal
            return
        }

        appState.isProcessing = true
        appState.lastError = nil
        print("[Upscale] start id=\(portrait.id) \(cg.width)×\(cg.height)")

        let birefnet = (modelManager?.useAdvancedModel == true) ? modelManager?.loadModel() : nil

        let portraitID = portrait.id
        Task.detached(priority: .userInitiated) {
            do {
                // 1. Upscale the original image (2× Lanczos + sharpen + denoise)
                guard let upscaled = ImageProcessor.upscale(image: cg) else {
                    await MainActor.run {
                        appState.lastError = Loc.upscaleFailed
                        appState.isProcessing = false
                    }
                    return
                }
                print("[Upscale] upscaled to \(upscaled.width)×\(upscaled.height)")

                // 2. Re-encode upscaled original as PNG data for storage
                guard let upscaledData = ImageProcessor.pngData(from: upscaled) else {
                    await MainActor.run {
                        appState.lastError = Loc.cannotSaveUpscaled
                        appState.isProcessing = false
                    }
                    return
                }

                // 3. Run the full pipeline on the upscaled image
                let processed = try ImageProcessor.process(image: upscaled, birefnetModel: birefnet)
                let pngData = ImageProcessor.pngData(from: processed.cutout) ?? Data()
                print("[Upscale] pipeline done cutout=\(processed.cutout.width)×\(processed.cutout.height) face=\(processed.faceRect ?? .zero)")

                await MainActor.run {
                    let descriptor = FetchDescriptor<Portrait>(
                        predicate: #Predicate { $0.id == portraitID }
                    )
                    guard let fresh = try? context.fetch(descriptor).first else {
                        appState.isProcessing = false
                        appState.lastError = Loc.portraitNotFound
                        return
                    }
                    // Update original with upscaled version
                    fresh.originalImageData = upscaledData
                    fresh.cutoutPNG = pngData
                    fresh.faceRect = processed.faceRect ?? .zero
                    fresh.eyeCenter = processed.eyeCenter
                    fresh.interEyeDistance = Double(processed.interEyeDistance ?? 0)
                    fresh.bodyBottomY = Double(processed.bodyBottomY)
                    // The cutout is now 2× larger in pixels. Halve the scale so
                    // the portrait stays the same visual size on the canvas.
                    // (cutoutW_new × scale_new == cutoutW_old × scale_old)
                    fresh.scale /= 2.0
                    fresh.isUpscaled = true
                    fresh.isAdvancedCutout = (birefnet != nil)
                    // Reset magic retouch flag since we have a fresh cutout
                    fresh.isMagicRetouched = false
                    fresh.preRetouchPNG = nil
                    fresh.didUpgradeCutout = false
                    fresh.preCutoutPNG = nil
                    fresh.updatedAt = Date()
                    try? context.save()
                    appState.invalidateCutout(for: fresh)
                    appState.isProcessing = false
                    print("[Upscale] DONE id=\(fresh.id)")
                }
            } catch {
                await MainActor.run {
                    appState.lastError = Loc.upscaleFailedErr(error.localizedDescription)
                    appState.isProcessing = false
                    print("[Upscale] ERROR \(error)")
                }
            }
        }
    }

    // MARK: - Magic Retouch

    /// Applies a one-click studio-quality enhancement (Apple auto-adjust +
    /// vibrance + shadow lift + warmth + sharpen) to the portrait's cutout.
    /// When the advanced BiRefNet model is available but hasn't been used for
    /// this portrait yet, the cutout is automatically upgraded first.
    /// The enhanced version replaces `cutoutPNG`; manual adjustment sliders
    /// still layer on top at render time.
    static func magicRetouch(portrait: Portrait, context: ModelContext, appState: AppState,
                             modelManager: ModelManager? = nil) {
        guard !portrait.isMagicRetouched else {
            appState.lastError = Loc.magicRetouchAlready
            return
        }
        guard let cutoutData = portrait.cutoutPNG,
              let cutoutCG = ImageProcessor.cgImage(from: cutoutData) else {
            appState.lastError = Loc.noCutoutAvailable
            return
        }

        // Determine if we should also upgrade the cutout to BiRefNet.
        let shouldUpgrade = modelManager?.isAvailable == true
            && modelManager?.useAdvancedModel == true
            && !portrait.isAdvancedCutout
            && portrait.originalImageData != nil

        appState.isProcessing = true
        appState.lastError = nil

        // Load the advanced model on the main thread before dispatching.
        let birefnet = shouldUpgrade ? modelManager?.loadModel() : nil
        let originalData = shouldUpgrade ? portrait.originalImageData : nil

        print("[MagicRetouch] start id=\(portrait.id) \(cutoutCG.width)×\(cutoutCG.height) upgrade=\(shouldUpgrade)")

        let portraitID = portrait.id
        Task.detached(priority: .userInitiated) {
            // Step 1: optionally upgrade the cutout to BiRefNet.
            var baseCutout = cutoutCG
            var upgradedPNG: Data?
            var upgradedFaceRect: CGRect?
            var upgradedEyeCenter: CGPoint?
            var upgradedIED: Double?
            var upgradedBodyBottom: CGFloat?

            if let model = birefnet, let origData = originalData,
               let originalCG = ImageProcessor.cgImage(from: origData) {
                do {
                    let processed = try ImageProcessor.process(image: originalCG, birefnetModel: model)
                    baseCutout = processed.cutout
                    upgradedPNG = ImageProcessor.pngData(from: processed.cutout)
                    upgradedFaceRect = processed.faceRect
                    upgradedEyeCenter = processed.eyeCenter
                    upgradedIED = processed.interEyeDistance.map(Double.init)
                    upgradedBodyBottom = processed.bodyBottomY
                    print("[MagicRetouch] cutout upgraded via BiRefNet")
                } catch {
                    // Fallback: proceed with retouch on the existing cutout.
                    print("[MagicRetouch] BiRefNet upgrade failed, continuing with existing cutout: \(error)")
                }
            }

            // Step 2: apply Magic Retouch filters.
            guard let enhanced = ImageProcessor.magicRetouch(image: baseCutout) else {
                await MainActor.run {
                    appState.lastError = Loc.magicRetouchFailed
                    appState.isProcessing = false
                }
                return
            }
            let pngData = ImageProcessor.pngData(from: enhanced) ?? Data()
            print("[MagicRetouch] done bytes=\(pngData.count)")

            await MainActor.run {
                let descriptor = FetchDescriptor<Portrait>(
                    predicate: #Predicate { $0.id == portraitID }
                )
                guard let fresh = try? context.fetch(descriptor).first else {
                    appState.isProcessing = false
                    appState.lastError = Loc.portraitNotFound
                    return
                }

                let didUpgrade = (upgradedPNG != nil)

                if didUpgrade {
                    // Back up the old (Apple Vision) cutout for combined undo.
                    fresh.preCutoutPNG = fresh.cutoutPNG
                    // Store the upgraded-but-unretouched cutout as preRetouchPNG
                    // so toggling retouch off still keeps the upgraded cutout…
                    // but we use preCutoutPNG for the full undo path.
                    fresh.preRetouchPNG = upgradedPNG
                    fresh.isAdvancedCutout = true
                    fresh.didUpgradeCutout = true
                    // Update face metrics from the new cutout.
                    if let fr = upgradedFaceRect { fresh.faceRect = fr }
                    if let ec = upgradedEyeCenter { fresh.eyeCenter = ec }
                    if let ied = upgradedIED { fresh.interEyeDistance = ied }
                    if let bb = upgradedBodyBottom { fresh.bodyBottomY = Double(bb) }
                } else {
                    fresh.preRetouchPNG = fresh.cutoutPNG
                    fresh.didUpgradeCutout = false
                }

                fresh.cutoutPNG = pngData
                fresh.isMagicRetouched = true
                fresh.updatedAt = Date()
                try? context.save()
                appState.invalidateCutout(for: fresh)
                appState.isProcessing = false
                print("[MagicRetouch] DONE id=\(fresh.id) upgraded=\(didUpgrade)")
            }
        }
    }

    /// Reverts Magic Retouch by restoring the pre-retouch cutout.
    /// When the retouch also upgraded the cutout model, both changes are undone.
    static func undoMagicRetouch(portrait: Portrait, context: ModelContext, appState: AppState) {
        guard portrait.isMagicRetouched else { return }

        if portrait.didUpgradeCutout, let originalCutout = portrait.preCutoutPNG {
            // Combined undo: restore the pre-upgrade (Apple Vision) cutout.
            portrait.cutoutPNG = originalCutout
            portrait.preCutoutPNG = nil
            portrait.isAdvancedCutout = false
            portrait.didUpgradeCutout = false
        } else if let preRetouch = portrait.preRetouchPNG {
            // Simple undo: restore pre-retouch cutout (same cutout model).
            portrait.cutoutPNG = preRetouch
        }

        portrait.preRetouchPNG = nil
        portrait.isMagicRetouched = false
        portrait.updatedAt = Date()
        try? context.save()
        appState.invalidateCutout(for: portrait)
    }

    // MARK: - Import Pipeline

    private static func runPipeline(cg: CGImage, originalData data: Data,
                                    suggestedName: String,
                                    context: ModelContext, appState: AppState,
                                    birefnetModel: MLModel? = nil) {
        Task.detached(priority: .userInitiated) {
            do {
                let processed = try ImageProcessor.process(image: cg, birefnetModel: birefnetModel)
                let cutoutSize = CGSize(width: processed.cutout.width, height: processed.cutout.height)
                let face = processed.faceRect ?? .zero
                print("[Import] subject lift OK cutout=\(processed.cutout.width)x\(processed.cutout.height) face=\(face)")

                let bodyBottom = processed.bodyBottomY
                let transform = (processed.faceRect != nil)
                    ? AutoAligner.computeTransform(
                        faceRect: face,
                        eyeCenter: processed.eyeCenter,
                        interEyeDistance: processed.interEyeDistance,
                        cutoutSize: cutoutSize,
                        bodyBottomY: bodyBottom)
                    : AutoAligner.fitTransform(cutoutSize: cutoutSize)
                print("[Import] transform scale=\(transform.scale) offset=\(transform.offset) bodyBottom=\(bodyBottom) eyes=\(processed.eyeCenter as Any) IPD=\(processed.interEyeDistance as Any)")

                let pngData = ImageProcessor.pngData(from: processed.cutout) ?? Data()
                print("[Import] PNG encoded bytes=\(pngData.count)")
                if pngData.isEmpty {
                    print("[Import] WARNING pngData is empty — cutout will be invisible!")
                }

                await MainActor.run {
                    let portrait = Portrait(
                        name: suggestedName,
                        cutoutPNG: pngData,
                        originalImageData: data,
                        faceRect: face,
                        eyeCenter: processed.eyeCenter,
                        interEyeDistance: Double(processed.interEyeDistance ?? 0),
                        bodyBottomY: Double(bodyBottom),
                        offsetX: Double(transform.offset.width),
                        offsetY: Double(transform.offset.height),
                        scale: Double(transform.scale)
                    )
                    portrait.isAdvancedCutout = (birefnetModel != nil)
                    context.insert(portrait)
                    try? context.save()
                    appState.selectedPortraitID = portrait.id
                    appState.isProcessing = false
                    print("[Import] DONE id=\(portrait.id)")
                }
            } catch {
                await MainActor.run {
                    appState.lastError = Loc.processingFailed(error.localizedDescription)
                    appState.isProcessing = false
                    print("[Import] ERROR \(error)")
                }
            }
        }
    }
}
