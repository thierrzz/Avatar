import Foundation
import SwiftData

@Model
final class Portrait {
    @Attribute(.unique) var id: UUID
    var name: String
    var tags: String
    var createdAt: Date
    var updatedAt: Date

    /// Bookmark or relative path to original imported file (kept for reprocessing).
    var originalImageData: Data?
    /// Cached subject-lift result (PNG with alpha) — re-usable across exports.
    @Attribute(.externalStorage) var cutoutPNG: Data?
    /// Detected face rect in cutout-image coordinates (normalized 0...1, origin top-left).
    var faceRectX: Double
    var faceRectY: Double
    var faceRectW: Double
    var faceRectH: Double

    /// Midpoint between the detected eyes, in cutout-pixel coordinates (top-left
    /// origin). (0, 0) means no eye data (legacy portraits or landmarks failed).
    var eyeCenterX: Double = 0
    var eyeCenterY: Double = 0
    /// Pixel distance between left- and right-eye centres in the cutout image.
    /// 0 means no eye data available — the aligner falls back to face-rect scaling.
    var interEyeDistance: Double = 0

    /// Y coordinate of the lowest visible body content in cutout-pixel space
    /// (top-left origin). Detected via body-pose estimation or alpha scan.
    /// 0 means not yet detected (legacy portraits before this field existed).
    var bodyBottomY: Double = 0

    // Manual transform overrides (canvas-space, canvas = 1024x1024)
    var offsetX: Double
    var offsetY: Double
    var scale: Double

    /// Selected background preset (nil = use default).
    var backgroundPresetID: UUID?

    // MARK: - Image adjustments (apply only to cutout, not background)
    //
    // All defaults are the "neutral" value for their filter so existing
    // portraits load unchanged after the model migration.
    var adjExposure: Double = 0        // EV stops, CIExposureAdjust
    var adjContrast: Double = 1.0      // CIColorControls.contrast (1 = neutral)
    var adjBrightness: Double = 0      // CIColorControls.brightness
    var adjSaturation: Double = 1.0    // CIColorControls.saturation (1 = neutral)
    var adjHue: Double = 0             // degrees, converted to radians for CIHueAdjust
    var adjTemperature: Double = 0     // Kelvin offset vs 6500 neutral
    var adjTint: Double = 0            // green/magenta offset
    var adjHighlights: Double = 1.0    // CIHighlightShadowAdjust.highlightAmount
    var adjShadows: Double = 0         // CIHighlightShadowAdjust.shadowAmount
    var adjWhites: Double = 0          // tone curve white-point offset
    var adjBlacks: Double = 0          // tone curve black-point offset

    // MARK: - Enhancement flags
    /// Whether the original image has been upscaled via CILanczosScaleTransform.
    /// Prevents double-upscaling and communicates state to the UI.
    var isUpscaled: Bool = false
    /// Whether Magic Retouch has been baked into the current cutoutPNG.
    /// Prevents double-application and communicates state to the UI.
    var isMagicRetouched: Bool = false
    /// Stores the pre-retouch cutout so Magic Retouch can be toggled off.
    @Attribute(.externalStorage) var preRetouchPNG: Data?

    init(
        id: UUID = UUID(),
        name: String = "",
        tags: String = "",
        cutoutPNG: Data? = nil,
        originalImageData: Data? = nil,
        faceRect: CGRect = .zero,
        eyeCenter: CGPoint? = nil,
        interEyeDistance: Double = 0,
        bodyBottomY: Double = 0,
        offsetX: Double = 0,
        offsetY: Double = 0,
        scale: Double = 1,
        backgroundPresetID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.tags = tags
        self.cutoutPNG = cutoutPNG
        self.originalImageData = originalImageData
        self.faceRectX = Double(faceRect.origin.x)
        self.faceRectY = Double(faceRect.origin.y)
        self.faceRectW = Double(faceRect.size.width)
        self.faceRectH = Double(faceRect.size.height)
        self.eyeCenterX = Double(eyeCenter?.x ?? 0)
        self.eyeCenterY = Double(eyeCenter?.y ?? 0)
        self.interEyeDistance = interEyeDistance
        self.bodyBottomY = bodyBottomY
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.scale = scale
        self.backgroundPresetID = backgroundPresetID
        let now = Date()
        self.createdAt = now
        self.updatedAt = now
    }

    var faceRect: CGRect {
        get { CGRect(x: faceRectX, y: faceRectY, width: faceRectW, height: faceRectH) }
        set {
            faceRectX = Double(newValue.origin.x)
            faceRectY = Double(newValue.origin.y)
            faceRectW = Double(newValue.size.width)
            faceRectH = Double(newValue.size.height)
        }
    }

    /// Midpoint between the eyes, or nil when no landmark data is available.
    var eyeCenter: CGPoint? {
        get { interEyeDistance > 0 ? CGPoint(x: eyeCenterX, y: eyeCenterY) : nil }
        set {
            eyeCenterX = Double(newValue?.x ?? 0)
            eyeCenterY = Double(newValue?.y ?? 0)
        }
    }
}
