import Foundation
import SwiftData
import AppKit
import UniformTypeIdentifiers
import CoreML

/// Centralised drop-handler used by every view that should accept a portrait
/// drag-and-drop (the empty-state import zone AND the editor surface, so users
/// can drop a fresh photo at any time without going back to an empty state).
@MainActor
enum PortraitDropHandler {
    static func handle(providers: [NSItemProvider],
                       context: ModelContext,
                       appState: AppState,
                       modelManager: ModelManager? = nil) -> Bool {
        guard let provider = providers.first else { return false }
        // Show feedback immediately — the loaders below are async.
        appState.isProcessing = true

        let fileURLType = UTType.fileURL.identifier
        if provider.hasItemConformingToTypeIdentifier(fileURLType) {
            provider.loadDataRepresentation(forTypeIdentifier: fileURLType) { data, _ in
                guard let data,
                      let urlString = String(data: data, encoding: .utf8),
                      let url = URL(string: urlString) ?? URL(dataRepresentation: data, relativeTo: nil)
                else {
                    Task { @MainActor in
                        appState.isProcessing = false
                        appState.lastError = Loc.dropPhotoNotFound
                        print("[Drop] failed to decode file URL")
                    }
                    return
                }
                Task { @MainActor in
                    ImportFlow.importFile(url: url, context: context, appState: appState,
                                         modelManager: modelManager)
                }
            }
            return true
        }

        let imageType = UTType.image.identifier
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
                    // Reset magic retouch flag since we have a fresh cutout
                    fresh.isMagicRetouched = false
                    fresh.preRetouchPNG = nil
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
    /// The enhanced version replaces `cutoutPNG`; manual adjustment sliders
    /// still layer on top at render time. "Opnieuw uitknippen" serves as undo.
    static func magicRetouch(portrait: Portrait, context: ModelContext, appState: AppState) {
        guard !portrait.isMagicRetouched else {
            appState.lastError = Loc.magicRetouchAlready
            return
        }
        guard let cutoutData = portrait.cutoutPNG,
              let cutoutCG = ImageProcessor.cgImage(from: cutoutData) else {
            appState.lastError = Loc.noCutoutAvailable
            return
        }

        appState.isProcessing = true
        appState.lastError = nil
        print("[MagicRetouch] start id=\(portrait.id) \(cutoutCG.width)×\(cutoutCG.height)")

        let portraitID = portrait.id
        Task.detached(priority: .userInitiated) {
            guard let enhanced = ImageProcessor.magicRetouch(image: cutoutCG) else {
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
                fresh.preRetouchPNG = fresh.cutoutPNG
                fresh.cutoutPNG = pngData
                fresh.isMagicRetouched = true
                fresh.updatedAt = Date()
                try? context.save()
                appState.invalidateCutout(for: fresh)
                appState.isProcessing = false
                print("[MagicRetouch] DONE id=\(fresh.id)")
            }
        }
    }

    /// Reverts Magic Retouch by restoring the pre-retouch cutout.
    static func undoMagicRetouch(portrait: Portrait, context: ModelContext, appState: AppState) {
        guard portrait.isMagicRetouched, let original = portrait.preRetouchPNG else { return }
        portrait.cutoutPNG = original
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
