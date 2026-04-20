import Foundation
import CoreImage
import AppKit

/// Thin wrapper around `BackendClient.extendBody` that re-segments the cloud
/// result back to an alpha cutout. The backend returns a full RGB image with
/// generated shoulders/torso; we run the standard subject-lift pipeline on it
/// so the rest of the app keeps receiving a transparent PNG with correct
/// `bodyBottomY` metadata.
@MainActor
enum ExtendBodyService {
    struct Result {
        let cutoutPNG: Data
        let bodyBottomY: CGFloat
        let faceRect: CGRect?
        let eyeCenter: CGPoint?
        let interEyeDistance: CGFloat?
    }

    /// Calls the backend, receives an extended RGB image, re-runs subject-lift,
    /// and returns a new cutout PNG plus updated metadata.
    /// - Throws: `BackendError.noCredits` → caller should show paywall.
    static func extend(portrait: Portrait,
                       backend: BackendClient,
                       modelManager: ModelManager? = nil) async throws -> Result {
        guard let cutoutData = portrait.cutoutPNG else {
            throw BackendError.server(0, "No cutout to extend")
        }

        // 1. Round-trip to the backend (which proxies Replicate flux-fill-pro).
        let extendedData = try await backend.extendBody(cutoutPNG: cutoutData)

        // 2. Decode the RGB result.
        guard let extendedCG = ImageProcessor.cgImage(from: extendedData) else {
            throw BackendError.decode
        }

        // 3. Re-segment using the same pipeline used at import time so the
        //    returned cutout has alpha + accurate bodyBottomY/face metadata.
        let birefnet = modelManager?.useAdvancedModel == true
            ? await modelManager?.loadModelAsync() : nil
        let processed = try ImageProcessor.process(image: extendedCG, birefnetModel: birefnet)

        guard let pngData = ImageProcessor.pngData(from: processed.cutout) else {
            throw BackendError.decode
        }

        return Result(
            cutoutPNG: pngData,
            bodyBottomY: processed.bodyBottomY,
            faceRect: processed.faceRect,
            eyeCenter: processed.eyeCenter,
            interEyeDistance: processed.interEyeDistance
        )
    }
}
