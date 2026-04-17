import Foundation
import CoreGraphics

/// Standard editing canvas. All offsets/scales are stored in this coordinate space
/// and remapped at export time, so visual layout is resolution-independent.
enum CanvasConstants {
    static let editCanvas = CGSize(width: 1024, height: 1024)

    // MARK: Eye-based alignment (preferred — consistent across faces)

    /// Target inter-eye distance as a fraction of canvas height.
    /// Because the distance between the eyes is nearly identical for every adult
    /// head (unlike face-rect height, which fluctuates with beard/hair/jaw shape),
    /// scaling to a fixed inter-eye target makes all heads the same size.
    static let targetInterEyeRatio: CGFloat = 0.12

    /// Vertical position of the eye midpoint, measured from the top of the canvas.
    static let targetEyeCenterY: CGFloat = 0.37

    /// Horizontal position of the eye midpoint (centred).
    static let targetEyeCenterX: CGFloat = 0.50

    // MARK: Face-rect fallback (used when no eye landmarks are available)

    /// Target proportion of canvas height that the face bounding-box should occupy.
    /// Tuned so the head + a bit of hair fits naturally.
    static let targetFaceHeightRatio: CGFloat = 0.38

    /// Vertical position of the face center, measured from the top of the canvas.
    /// 0.42 leaves room for hair/crown above and shoulders below.
    static let targetFaceCenterY: CGFloat = 0.42

    /// Horizontal center.
    static let targetFaceCenterX: CGFloat = 0.50
}

struct AlignTransform: Equatable {
    var scale: CGFloat
    var offset: CGSize
}

enum AutoAligner {
    /// How far past the canvas bottom the body content should extend, as a
    /// fraction of canvas height. A small overshoot ensures the person looks
    /// like they naturally continue out of frame rather than ending abruptly.
    static let bodyOvershoot: CGFloat = 0.03

    /// Computes a transform such that, when the cutout is drawn at
    /// `(offset.x, offset.y)` scaled by `scale`, the portrait's eyes land at
    /// a canonical position and size (consistent across every portrait in the
    /// library).
    ///
    /// **Eye-based mode** (preferred): when `eyeCenter` and `interEyeDistance`
    /// are provided, the eye midpoint is placed at a fixed canvas position and
    /// the image is scaled so the inter-eye distance is identical for every
    /// portrait. This produces rock-solid alignment because the distance
    /// between the eyes is nearly the same for every adult, unlike the
    /// face-rect height which varies with beard, hair, and jaw shape.
    ///
    /// **Face-rect fallback**: when eye data is unavailable (no landmarks
    /// detected), the face bounding-box centre and height are used — the same
    /// behaviour as before eye-landmark support was added.
    ///
    /// When `bodyBottomY` is provided and greater than the anchor point, the
    /// scale is boosted (if needed) so the body content extends past the
    /// canvas bottom, preventing an unnatural gap beneath a short torso.
    ///
    /// - Parameters:
    ///   - faceRect: Face bounding box in cutout-pixel coordinates (top-left origin).
    ///   - eyeCenter: Midpoint between the two eyes (cutout pixels, top-left origin).
    ///     Pass nil to use the face-rect fallback.
    ///   - interEyeDistance: Pixel distance between the eye centres in the cutout.
    ///     Pass nil or 0 to use the face-rect fallback.
    ///   - cutoutSize: Pixel size of the cutout image.
    ///   - bodyBottomY: Y of the lowest visible body content in cutout-pixel coordinates
    ///     (top-left origin). Pass 0 to skip body-aware scaling.
    ///   - canvas: Edit canvas size (typically `CanvasConstants.editCanvas`).
    static func computeTransform(
        faceRect: CGRect,
        eyeCenter: CGPoint? = nil,
        interEyeDistance: CGFloat? = nil,
        cutoutSize: CGSize,
        bodyBottomY: CGFloat = 0,
        canvas: CGSize = CanvasConstants.editCanvas
    ) -> AlignTransform {
        guard faceRect.height > 0 else {
            return AlignTransform(scale: 1, offset: .zero)
        }

        let anchorX: CGFloat
        let anchorY: CGFloat
        let targetCX: CGFloat
        let targetCY: CGFloat
        var scale: CGFloat

        if let eyeCenter, let ied = interEyeDistance, ied > 0 {
            // ── Eye-based alignment (precise & consistent) ──────────
            anchorX  = eyeCenter.x
            anchorY  = eyeCenter.y
            targetCX = canvas.width  * CanvasConstants.targetEyeCenterX
            targetCY = canvas.height * CanvasConstants.targetEyeCenterY
            scale    = (canvas.height * CanvasConstants.targetInterEyeRatio) / ied
        } else {
            // ── Fallback: face-rect centre ──────────────────────────
            anchorX  = faceRect.midX
            anchorY  = faceRect.midY
            targetCX = canvas.width  * CanvasConstants.targetFaceCenterX
            targetCY = canvas.height * CanvasConstants.targetFaceCenterY
            scale    = (canvas.height * CanvasConstants.targetFaceHeightRatio) / faceRect.height
        }

        // Body-aware minimum scale: ensure the body content extends past the
        // canvas bottom (+ a small overshoot so it looks like the person
        // continues out of frame).
        if bodyBottomY > anchorY {
            let requiredBottom = canvas.height * (1.0 + bodyOvershoot)
            let minScale = (requiredBottom - targetCY) / (bodyBottomY - anchorY)
            scale = max(scale, minScale)
        }

        let offsetX = targetCX - anchorX * scale
        let offsetY = targetCY - anchorY * scale
        return AlignTransform(scale: scale, offset: CGSize(width: offsetX, height: offsetY))
    }

    /// Fallback when no face is detected: fit the cutout into the canvas with some padding
    /// and center it.
    static func fitTransform(cutoutSize: CGSize, canvas: CGSize = CanvasConstants.editCanvas) -> AlignTransform {
        let padding: CGFloat = 0.85
        let scale = min(canvas.width / cutoutSize.width, canvas.height / cutoutSize.height) * padding
        let scaledW = cutoutSize.width * scale
        let scaledH = cutoutSize.height * scale
        let offset = CGSize(
            width: (canvas.width - scaledW) / 2,
            height: (canvas.height - scaledH) / 2
        )
        return AlignTransform(scale: scale, offset: offset)
    }
}
