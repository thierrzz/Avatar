import Foundation
import SwiftData
import AppKit
import UniformTypeIdentifiers
import CoreML

/// Supported image types for import.
private let supportedImageUTIs: Set<String> = [
    UTType.jpeg.identifier,
    UTType.png.identifier,
    UTType.heic.identifier,
    UTType.tiff.identifier,
    UTType.bmp.identifier,
    UTType.gif.identifier,
]

/// Checks if the file extension is a supported image type.
private func isSupportedImageFile(_ url: URL) -> Bool {
    guard let ext = url.pathExtension.lowercased() as String? else { return false }
    switch ext {
    case "jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "bmp", "gif": return true
    default: return false
    }
}

/// Simple image format validation (magic bytes).
private func isValidImageData(_ data: Data) -> Bool {
    guard data.count >= 12 else { return false }
    let bytes = [UInt8](data.prefix(12))
    // PNG: 89 50 4E 47 0D 0A 1A 0A
    if bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47 { return true }
    // JPEG: FF D8 FF
    if bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF { return true }
    // GIF: 47 49 46 38
    if bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x38 { return true }
    // BMP / TIFF: starts with "BM" or "II" or "MM"
    if bytes[0] == 0x42 && bytes[1] == 0x4D { return true }
    if bytes[0] == 0x49 && bytes[1] == 0x49 { return true }
    if bytes[0] == 0x4D && bytes[1] == 0x4D { return true }
    return false
}

/// Logs and swallows save errors to avoid crashing the UI on transient issues.
/// Uses os_log in production; good for debugging.
@discardableResult
private func save(_ context: ModelContext) -> Bool {
    do {
        try context.save()
        return true
    } catch {
        print("[Save] failed: \(error)")
        return false
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
                guard isSupportedImageFile(url) else {
                    Task { @MainActor in
                        appState.isProcessing = false
                        appState.lastError = Loc.unknownFileType
                        print("[Drop] unsupported file type: \(url.pathExtension)")
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
                guard isValidImageData(data) else {
                    Task { @MainActor in
                        appState.isProcessing = false
                        appState.lastError = Loc.unknownFileType
                        print("[Drop] invalid image data")
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
    /// File I/O, image decode, and the BiRefNet model load all happen on a
    /// background task so the main thread stays responsive during large
    /// HEIC/PNG reads and the first-time Neural Engine compile.
    static func importFile(url: URL, context: ModelContext, appState: AppState,
                           modelManager: ModelManager? = nil) {
        appState.isProcessing = true
        appState.lastError = nil
        print("[Import] start url=\(url.path)")

        let useAdvanced = modelManager?.useAdvancedModel == true
        let suggestedName = url.deletingPathExtension().lastPathComponent

        Task.detached(priority: .userInitiated) {
            // Re-anchor the security-scoped access on the background thread
            // that will actually read the file.
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                await MainActor.run {
                    appState.lastError = Loc.cannotReadFile(error.localizedDescription)
                    appState.isProcessing = false
                    print("[Import] FAILED Data(contentsOf:) error=\(error)")
                }
                return
            }
            print("[Import] read bytes=\(data.count)")

            guard let cg = ImageProcessor.cgImage(from: data) else {
                await MainActor.run {
                    appState.lastError = Loc.cannotDecodeImage
                    appState.isProcessing = false
                    print("[Import] FAILED CGImage decode (data was \(data.count) bytes)")
                }
                return
            }
            print("[Import] loaded CGImage \(cg.width)x\(cg.height)")

            let birefnet: MLModel? = useAdvanced ? await modelManager?.loadModelAsync() : nil
            await runPipeline(cg: cg, originalData: data, suggestedName: suggestedName,
                              context: context, appState: appState, birefnetModel: birefnet)
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

        let useAdvanced = modelManager?.useAdvancedModel == true

        Task.detached(priority: .userInitiated) {
            guard let cg = ImageProcessor.cgImage(from: data) else {
                await MainActor.run {
                    appState.lastError = Loc.cannotDecodeImage
                    appState.isProcessing = false
                    print("[Import] FAILED CGImage decode from raw data")
                }
                return
            }
            let birefnet: MLModel? = useAdvanced ? await modelManager?.loadModelAsync() : nil
            await runPipeline(cg: cg, originalData: data, suggestedName: suggestedName,
                              context: context, appState: appState, birefnetModel: birefnet)
        }
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

        let useAdvanced = modelManager?.useAdvancedModel == true
        let portraitID = portrait.id
        Task.detached(priority: .userInitiated) {
            // Load the advanced model off the main thread — the first-time
            // Neural Engine compile otherwise freezes the UI.
            let birefnet: MLModel? = useAdvanced ? await modelManager?.loadModelAsync() : nil
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
                    save(context)
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

    /// Runs an on-device Real-ESRGAN super-resolution model on the portrait's
    /// original image (2× or 4× depending on the selected variant), then
    /// re-runs the cutout pipeline from the higher-resolution source. Caller
    /// is expected to guarantee `upscaleManager.isAnyInstalled` — the UI
    /// disables the Upscale button otherwise.
    static func upscale(portrait: Portrait, context: ModelContext, appState: AppState,
                        modelManager: ModelManager? = nil,
                        upscaleManager: UpscaleModelManager) {
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
        guard upscaleManager.isAnyInstalled else {
            appState.lastError = Loc.upscaleModelNotInstalled
            return
        }

        appState.processingKind = .upscale
        appState.isProcessing = true
        appState.lastError = nil
        print("[Upscale] start id=\(portrait.id) \(cg.width)×\(cg.height)")

        let useAdvanced = modelManager?.useAdvancedModel == true
        let portraitID = portrait.id
        Task.detached(priority: .userInitiated) {
            guard let active = await upscaleManager.activeModelAsync() else {
                await MainActor.run {
                    appState.lastError = Loc.upscaleModelNotInstalled
                    appState.isProcessing = false
                }
                return
            }
            let upscaleModel = active.model
            let factor = active.variant.factor
            let birefnet: MLModel? = useAdvanced ? await modelManager?.loadModelAsync() : nil

            do {
                // 1. AI super-resolve the original image.
                let upscaled = try ImageProcessor.upscale(image: cg, using: upscaleModel, factor: factor)
                print("[Upscale] upscaled to \(upscaled.width)×\(upscaled.height) (×\(factor))")

                // 2. Re-encode the upscaled original for persistent storage.
                guard let upscaledData = ImageProcessor.pngData(from: upscaled) else {
                    await MainActor.run {
                        appState.lastError = Loc.cannotSaveUpscaled
                        appState.isProcessing = false
                    }
                    return
                }

                // 3. Re-run the cutout pipeline from the higher-resolution source.
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
                    // Snapshot pre-upscale state so Upscale can be toggled off.
                    fresh.preUpscaleOriginalData = fresh.originalImageData
                    fresh.preUpscaleCutoutPNG = fresh.cutoutPNG
                    fresh.preUpscaleFaceRectX = fresh.faceRectX
                    fresh.preUpscaleFaceRectY = fresh.faceRectY
                    fresh.preUpscaleFaceRectW = fresh.faceRectW
                    fresh.preUpscaleFaceRectH = fresh.faceRectH
                    if let eye = fresh.eyeCenter {
                        fresh.preUpscaleEyeCenterX = Double(eye.x)
                        fresh.preUpscaleEyeCenterY = Double(eye.y)
                        fresh.preUpscaleHasEyes = true
                    } else {
                        fresh.preUpscaleHasEyes = false
                    }
                    fresh.preUpscaleInterEyeDistance = fresh.interEyeDistance
                    fresh.preUpscaleBodyBottomY = fresh.bodyBottomY
                    fresh.preUpscaleFactor = factor

                    fresh.originalImageData = upscaledData
                    fresh.cutoutPNG = pngData
                    fresh.faceRect = processed.faceRect ?? .zero
                    fresh.eyeCenter = processed.eyeCenter
                    fresh.interEyeDistance = Double(processed.interEyeDistance ?? 0)
                    fresh.bodyBottomY = Double(processed.bodyBottomY)
                    // The cutout is now `factor`× larger in pixels. Divide the
                    // canvas scale by the same factor so visual size stays
                    // stable; exports downsample from a genuinely higher-res
                    // cutout, which is where the win shows up.
                    fresh.scale /= Double(factor)
                    fresh.isUpscaled = true
                    fresh.isMagicRetouched = false
                    fresh.preRetouchPNG = nil
                    fresh.updatedAt = Date()
                    save(context)
                    appState.invalidateCutout(for: fresh)
                    appState.isProcessing = false
                    print("[Upscale] DONE id=\(fresh.id) factor=\(factor)")
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

    /// Reverts an Upscale by restoring the pre-upscale snapshot (original data,
    /// cutout, face metrics) and doubling the manual scale back to compensate.
    static func undoUpscale(portrait: Portrait, context: ModelContext, appState: AppState) {
        guard portrait.isUpscaled,
              let origData = portrait.preUpscaleOriginalData,
              let cutoutData = portrait.preUpscaleCutoutPNG else {
            return
        }
        portrait.originalImageData = origData
        portrait.cutoutPNG = cutoutData
        portrait.faceRectX = portrait.preUpscaleFaceRectX
        portrait.faceRectY = portrait.preUpscaleFaceRectY
        portrait.faceRectW = portrait.preUpscaleFaceRectW
        portrait.faceRectH = portrait.preUpscaleFaceRectH
        if portrait.preUpscaleHasEyes {
            portrait.eyeCenterX = portrait.preUpscaleEyeCenterX
            portrait.eyeCenterY = portrait.preUpscaleEyeCenterY
        } else {
            portrait.eyeCenterX = 0
            portrait.eyeCenterY = 0
        }
        portrait.interEyeDistance = portrait.preUpscaleInterEyeDistance
        portrait.bodyBottomY = portrait.preUpscaleBodyBottomY
        // Restore the visual scale (was divided by the factor at upscale time).
        let storedFactor = portrait.preUpscaleFactor > 0 ? portrait.preUpscaleFactor : 2
        portrait.scale *= Double(storedFactor)
        portrait.isUpscaled = false
        // Magic Retouch was cleared at upscale time; pre-upscale cutout is raw.
        portrait.isMagicRetouched = false
        portrait.preRetouchPNG = nil
        // Drop the snapshot — re-running Upscale will take a fresh one.
        portrait.preUpscaleOriginalData = nil
        portrait.preUpscaleCutoutPNG = nil
        portrait.updatedAt = Date()
        save(context)
        appState.invalidateCutout(for: portrait)
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
                save(context)
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
        save(context)
        appState.invalidateCutout(for: portrait)
    }

    // MARK: - Extend Body (Pro)

    /// Calls the backend (Replicate flux-fill-pro proxy) to outpaint missing
    /// shoulders/torso, re-segments the result, and replaces `cutoutPNG`.
    /// Snapshots the pre-extend state so the operation can be toggled off.
    ///
    /// Precondition: the caller must already have verified that the user is
    /// signed in *and* has at least one credit. If the backend returns 402
    /// anyway (race), this method re-opens the upgrade sheet.
    static func extendBody(portrait: Portrait, context: ModelContext, appState: AppState,
                           modelManager: ModelManager? = nil) {
        guard !portrait.isBodyExtended else {
            appState.lastError = Loc.extendBodyAlreadyComplete
            return
        }
        guard portrait.cutoutPNG != nil else {
            appState.lastError = Loc.extendBodyNoCutout
            return
        }

        appState.isProcessing = true
        appState.lastError = nil
        let portraitID = portrait.id
        let backend = appState.backend
        print("[ExtendBody] start id=\(portraitID)")

        Task {
            do {
                let result = try await ExtendBodyService.extend(
                    portrait: portrait, backend: backend, modelManager: modelManager
                )

                let descriptor = FetchDescriptor<Portrait>(
                    predicate: #Predicate { $0.id == portraitID }
                )
                guard let fresh = try? context.fetch(descriptor).first else {
                    appState.isProcessing = false
                    appState.lastError = Loc.portraitNotFound
                    return
                }

                // Snapshot pre-extend state so the op can be toggled off.
                fresh.preExtendBodyCutoutPNG = fresh.cutoutPNG
                fresh.preExtendBodyBodyBottomY = fresh.bodyBottomY
                fresh.preExtendBodyOffsetX = fresh.offsetX
                fresh.preExtendBodyOffsetY = fresh.offsetY
                fresh.preExtendBodyScale = fresh.scale

                // Apply new cutout + metadata.
                fresh.cutoutPNG = result.cutoutPNG
                fresh.bodyBottomY = Double(result.bodyBottomY)
                if let face = result.faceRect { fresh.faceRect = face }
                if let eye = result.eyeCenter {
                    fresh.eyeCenterX = Double(eye.x)
                    fresh.eyeCenterY = Double(eye.y)
                }
                if let d = result.interEyeDistance {
                    fresh.interEyeDistance = Double(d)
                }
                fresh.isBodyExtended = true
                fresh.updatedAt = Date()
                save(context)

                // Refresh entitlement so the credits counter reflects the spend.
                appState.refreshEntitlement()

                appState.invalidateCutout(for: fresh)
                appState.isProcessing = false
                print("[ExtendBody] DONE id=\(fresh.id)")
            } catch BackendError.notSignedIn {
                appState.isProcessing = false
                appState.showSignInPrompt = true
            } catch BackendError.noCredits {
                appState.isProcessing = false
                appState.showProUpgradeSheet = true
                appState.refreshEntitlement()
            } catch {
                appState.isProcessing = false
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                appState.lastError = Loc.extendBodyFailed(msg)
                print("[ExtendBody] ERROR \(error)")
            }
        }
    }

    /// Reverts Extend Body by restoring the pre-extend snapshot.
    static func undoExtendBody(portrait: Portrait, context: ModelContext, appState: AppState) {
        guard portrait.isBodyExtended,
              let original = portrait.preExtendBodyCutoutPNG else { return }
        portrait.cutoutPNG = original
        portrait.bodyBottomY = portrait.preExtendBodyBodyBottomY
        portrait.offsetX = portrait.preExtendBodyOffsetX
        portrait.offsetY = portrait.preExtendBodyOffsetY
        portrait.scale = portrait.preExtendBodyScale
        portrait.isBodyExtended = false
        portrait.preExtendBodyCutoutPNG = nil
        portrait.updatedAt = Date()
        save(context)
        appState.invalidateCutout(for: portrait)
    }

    // MARK: - Import Pipeline

    /// Runs the cutout + auto-align pipeline and inserts a Portrait. Must be
    /// called from a background context (the ImageProcessor work is CPU/ANE
    /// heavy); it hops back to the main actor only for the SwiftData write.
    nonisolated private static func runPipeline(
        cg: CGImage, originalData data: Data,
        suggestedName: String,
        context: ModelContext, appState: AppState,
        birefnetModel: MLModel? = nil
    ) async {
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
                save(context)
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
