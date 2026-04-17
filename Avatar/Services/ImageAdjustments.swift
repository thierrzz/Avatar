import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// Plain value representation of a portrait's cutout adjustments.
/// Kept separate from `Portrait` so rendering code doesn't depend on SwiftData.
struct ImageAdjustments: Equatable, Hashable {
    var exposure: Double
    var contrast: Double
    var brightness: Double
    var saturation: Double
    var hue: Double          // degrees (-180...180)
    var temperature: Double  // Kelvin offset vs 6500 neutral
    var tint: Double         // green/magenta offset
    var highlights: Double   // 0...1
    var shadows: Double      // 0...1
    var whites: Double       // -1...1
    var blacks: Double       // -1...1

    static let neutral = ImageAdjustments(
        exposure: 0,
        contrast: 1,
        brightness: 0,
        saturation: 1,
        hue: 0,
        temperature: 0,
        tint: 0,
        highlights: 1,
        shadows: 0,
        whites: 0,
        blacks: 0
    )

    var isNeutral: Bool { self == .neutral }

    init(
        exposure: Double,
        contrast: Double,
        brightness: Double,
        saturation: Double,
        hue: Double,
        temperature: Double,
        tint: Double,
        highlights: Double,
        shadows: Double,
        whites: Double,
        blacks: Double
    ) {
        self.exposure = exposure
        self.contrast = contrast
        self.brightness = brightness
        self.saturation = saturation
        self.hue = hue
        self.temperature = temperature
        self.tint = tint
        self.highlights = highlights
        self.shadows = shadows
        self.whites = whites
        self.blacks = blacks
    }

    init(from portrait: Portrait) {
        self.init(
            exposure: portrait.adjExposure,
            contrast: portrait.adjContrast,
            brightness: portrait.adjBrightness,
            saturation: portrait.adjSaturation,
            hue: portrait.adjHue,
            temperature: portrait.adjTemperature,
            tint: portrait.adjTint,
            highlights: portrait.adjHighlights,
            shadows: portrait.adjShadows,
            whites: portrait.adjWhites,
            blacks: portrait.adjBlacks
        )
    }
}

/// Applies an `ImageAdjustments` filter chain to a CGImage using the shared
/// `ImageProcessor.ciContext` (GPU-backed). Returns the input unchanged when
/// adjustments are neutral so callers can stay on the fast path.
enum ImageAdjustmentRenderer {
    static func apply(_ a: ImageAdjustments, to image: CGImage) -> CGImage? {
        if a.isNeutral { return image }

        // Preserve the original extent so the filter chain doesn't expand or
        // shift the image (some filters like CIHighlightShadowAdjust do).
        let source = CIImage(cgImage: image)
        let extent = source.extent
        var current: CIImage = source

        // 1. Exposure
        if a.exposure != 0 {
            let f = CIFilter.exposureAdjust()
            f.inputImage = current
            f.ev = Float(a.exposure)
            if let out = f.outputImage { current = out }
        }

        // 2. Contrast / Brightness / Saturation (single pass)
        if a.contrast != 1 || a.brightness != 0 || a.saturation != 1 {
            let f = CIFilter.colorControls()
            f.inputImage = current
            f.contrast = Float(a.contrast)
            f.brightness = Float(a.brightness)
            f.saturation = Float(a.saturation)
            if let out = f.outputImage { current = out }
        }

        // 3. Temperature / Tint — 6500K neutral, positive temperature warms.
        if a.temperature != 0 || a.tint != 0 {
            let f = CIFilter.temperatureAndTint()
            f.inputImage = current
            f.neutral = CIVector(x: 6500, y: 0)
            f.targetNeutral = CIVector(x: CGFloat(6500 + a.temperature), y: CGFloat(a.tint))
            if let out = f.outputImage { current = out }
        }

        // 4. Highlights / Shadows
        if a.highlights != 1 || a.shadows != 0 {
            let f = CIFilter.highlightShadowAdjust()
            f.inputImage = current
            f.highlightAmount = Float(a.highlights)
            f.shadowAmount = Float(a.shadows)
            if let out = f.outputImage { current = out }
        }

        // 5. Whites / Blacks via tone curve — shifts the endpoints of the
        //    curve. Positive whites brightens the white point; positive blacks
        //    lifts the black point (negative crushes).
        if a.whites != 0 || a.blacks != 0 {
            let f = CIFilter.toneCurve()
            f.inputImage = current
            let blackY = max(0, min(1, 0 + a.blacks))
            let whiteY = max(0, min(1, 1 + a.whites))
            f.point0 = CGPoint(x: 0,    y: blackY)
            f.point1 = CGPoint(x: 0.25, y: 0.25 + a.blacks * 0.5)
            f.point2 = CGPoint(x: 0.5,  y: 0.5)
            f.point3 = CGPoint(x: 0.75, y: 0.75 + a.whites * 0.5)
            f.point4 = CGPoint(x: 1,    y: whiteY)
            if let out = f.outputImage { current = out }
        }

        // 6. Hue (degrees → radians)
        if a.hue != 0 {
            let f = CIFilter.hueAdjust()
            f.inputImage = current
            f.angle = Float(a.hue * .pi / 180)
            if let out = f.outputImage { current = out }
        }

        let outputCS = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return ImageProcessor.ciContext.createCGImage(current, from: extent, format: .RGBA8, colorSpace: outputCS)
    }
}
