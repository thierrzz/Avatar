import Foundation
import CoreGraphics
import AppKit

enum Compositor {
    /// Renders the final portrait at the requested output size by:
    /// 1. Filling background (color or image, aspect-fill).
    /// 2. Drawing the cutout with the stored canvas-space transform,
    ///    rescaled from the edit canvas (1024x1024) to the export size.
    /// 3. Optionally clipping to a circle (transparent corners).
    static func render(
        cutout: CGImage,
        background: BackgroundLayer,
        transform: AlignTransform,
        outputSize: CGSize,
        shape: ExportShape
    ) -> CGImage? {
        let width  = Int(outputSize.width)
        let height = Int(outputSize.height)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .high
        ctx.setShouldAntialias(true)

        // Use a flipped coordinate system so transforms saved in the editor
        // (top-left origin) match what we draw here.
        ctx.translateBy(x: 0, y: outputSize.height)
        ctx.scaleBy(x: 1, y: -1)

        // Circle clip if needed (clip BEFORE drawing so background also gets clipped).
        if shape == .circle {
            let path = CGPath(ellipseIn: CGRect(origin: .zero, size: outputSize), transform: nil)
            ctx.addPath(path)
            ctx.clip()
        }

        // 1. Background
        drawBackground(background, in: ctx, size: outputSize)

        // 2. Cutout — remap from edit canvas to output size.
        let editCanvas = CanvasConstants.editCanvas
        let scaleX = outputSize.width / editCanvas.width
        let scaleY = outputSize.height / editCanvas.height

        let cutoutW = CGFloat(cutout.width) * transform.scale * scaleX
        let cutoutH = CGFloat(cutout.height) * transform.scale * scaleY
        let drawX = transform.offset.width * scaleX
        let drawY = transform.offset.height * scaleY

        ctx.draw(cutout, in: CGRect(x: drawX, y: drawY, width: cutoutW, height: cutoutH))

        return ctx.makeImage()
    }

    private static func drawBackground(_ bg: BackgroundLayer, in ctx: CGContext, size: CGSize) {
        switch bg {
        case .color(let r, let g, let b, let a):
            ctx.setFillColor(red: r, green: g, blue: b, alpha: a)
            ctx.fill(CGRect(origin: .zero, size: size))
        case .image(let img):
            // Aspect-fill
            let imgW = CGFloat(img.width)
            let imgH = CGFloat(img.height)
            let imgAspect = imgW / imgH
            let outAspect = size.width / size.height
            var drawRect: CGRect
            if imgAspect > outAspect {
                let h = size.height
                let w = h * imgAspect
                drawRect = CGRect(x: (size.width - w) / 2, y: 0, width: w, height: h)
            } else {
                let w = size.width
                let h = w / imgAspect
                drawRect = CGRect(x: 0, y: (size.height - h) / 2, width: w, height: h)
            }
            ctx.draw(img, in: drawRect)
        }
    }
}

/// Resolved background ready to draw.
enum BackgroundLayer {
    case color(CGFloat, CGFloat, CGFloat, CGFloat)
    case image(CGImage)

    static func resolve(preset: BackgroundPreset?, fallback: CGImage?) -> BackgroundLayer {
        if let preset = preset {
            switch preset.kind {
            case .color:
                let c = preset.colorComponents
                return .color(CGFloat(c.0), CGFloat(c.1), CGFloat(c.2), CGFloat(c.3))
            case .image:
                if let data = preset.imageData,
                   let img = ImageProcessor.cgImage(from: data) {
                    return .image(img)
                }
            }
        }
        if let fb = fallback {
            return .image(fb)
        }
        return .color(0.94, 0.95, 0.97, 1.0)
    }
}
