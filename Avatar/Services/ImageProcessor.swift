import Foundation
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreML
import AppKit

enum ImageProcessorError: Error {
    case noSubjectFound
    case maskGenerationFailed
    case cgImageCreationFailed
}

struct ProcessedSubject {
    /// Cutout image (RGBA with transparent background) sized to the source image.
    let cutout: CGImage
    /// Face rect in cutout image coordinates (origin top-left, in pixels).
    /// nil if no face was detected.
    let faceRect: CGRect?
    /// Midpoint between the two eyes in cutout-pixel coordinates (top-left origin).
    /// nil when face-landmark detection couldn't locate both eyes.
    let eyeCenter: CGPoint?
    /// Pixel distance between left- and right-eye centres.  A much more stable
    /// metric than face-rect height for normalising head size across people
    /// (beards, hair, jaw shape don't affect it).
    let interEyeDistance: CGFloat?
    /// Y coordinate (top-left origin, pixels) of the lowest visible body content.
    /// Determined by body-pose detection or alpha-channel scan.
    let bodyBottomY: CGFloat
}

/// Intermediate result from combined face-rect + landmark detection.
struct FaceDetectionResult {
    let faceRect: CGRect           // image pixels, origin top-left
    let eyeCenter: CGPoint?        // midpoint between eyes, pixels, top-left
    let interEyeDistance: CGFloat?  // pixel distance between eye centres
}

enum ImageProcessor {
    static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Removes the background using Vision's foreground instance mask
    /// (the same "Subject Lift" model the Photos app uses, macOS 14+) and
    /// refines the matte with `VNGeneratePersonSegmentationRequest(.accurate)`
    /// for smoother hair edges. Falls back to the raw foreground mask when
    /// person segmentation has nothing useful (e.g. non-person subjects).
    static func subjectLift(image: CGImage) throws -> CGImage {
        let foreground = VNGenerateForegroundInstanceMaskRequest()
        let personSeg = VNGeneratePersonSegmentationRequest()
        personSeg.qualityLevel = .accurate
        personSeg.outputPixelFormat = kCVPixelFormatType_OneComponent8

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        // Run in one perform() so Vision can share resources; person seg is
        // allowed to fail without aborting the whole pipeline.
        try handler.perform([foreground, personSeg])

        guard let fgObservation = foreground.results?.first else {
            throw ImageProcessorError.noSubjectFound
        }

        // 1. Grab the foreground instance mask as a soft grayscale CIImage.
        let fgMaskPB = try fgObservation.generateScaledMaskForImage(
            forInstances: fgObservation.allInstances,
            from: handler
        )
        let fgMaskRaw = CIImage(cvPixelBuffer: fgMaskPB)
        let originalCI = CIImage(cgImage: image)
        let extent = originalCI.extent

        // Vision returns masks at the model's native resolution. Scale them up
        // (and pin the extent) so every later composite aligns with the source.
        let fgMask = scaleMaskToExtent(fgMaskRaw, extent: extent)

        // 2. Person segmentation matte — optional refinement for hair edges.
        let personMask: CIImage? = {
            guard let buffer = (personSeg.results?.first)?.pixelBuffer else { return nil }
            return scaleMaskToExtent(CIImage(cvPixelBuffer: buffer), extent: extent)
        }()

        // 3. Combine the two masks into a single refined alpha matte.
        //    The original image is passed as a guide for edge-aware refinement
        //    so the matte aligns with true hair/edge boundaries in the photo.
        let refinedMask = refineAlphaMatte(foreground: fgMask, personSeg: personMask, guide: originalCI, extent: extent)

        // 4. Re-composite original RGB with the new alpha. Using the original
        //    colors (instead of Vision's pre-masked buffer) avoids the dark
        //    halo that appears when blurring premultiplied edge pixels.
        //    `CIMaskToAlpha` turns the grayscale matte into an alpha channel
        //    so `CIBlendWithMask` reads opacity correctly regardless of
        //    whether Vision gave us a luminance- or alpha-coded buffer.
        let clearBG = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
            .cropped(to: extent)
        let alphaMatte = refinedMask.applyingFilter("CIMaskToAlpha")
        let composed = originalCI.applyingFilter("CIBlendWithMask", parameters: [
            "inputBackgroundImage": clearBG,
            "inputMaskImage": alphaMatte
        ]).cropped(to: extent)

        let outputCS = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let cg = ciContext.createCGImage(composed, from: extent, format: .RGBA8, colorSpace: outputCS) else {
            throw ImageProcessorError.maskGenerationFailed
        }
        return cg
    }

    /// Combines the foreground instance mask with the (optional) person-segmentation
    /// matte and polishes the alpha channel so hair and soft edges survive while
    /// background-colour fringing is knocked back.
    ///
    /// The `guide` parameter is the original RGB image. It drives a guided-filter
    /// pass that snaps the soft matte boundary onto real luminance edges in the
    /// photo — recovering fine hair strands that morphology alone would clip.
    private static func refineAlphaMatte(
        foreground: CIImage,
        personSeg: CIImage?,
        guide: CIImage,
        extent: CGRect
    ) -> CIImage {
        // Union with person segmentation (max) — hair strands the foreground
        // mask chops off usually survive in the person matte. We gate the
        // union through a slightly dilated foreground mask so person-seg
        // false positives elsewhere in the frame don't sneak in.
        var combined = foreground
        if let personSeg = personSeg {
            let gate = foreground.applyingFilter("CIMorphologyMaximum", parameters: [
                kCIInputRadiusKey: 8.0
            ]).cropped(to: extent)
            let gatedPerson = personSeg.applyingFilter("CIDarkenBlendMode", parameters: [
                kCIInputBackgroundImageKey: gate
            ]).cropped(to: extent)
            combined = combined.applyingFilter("CILightenBlendMode", parameters: [
                kCIInputBackgroundImageKey: gatedPerson
            ]).cropped(to: extent)
        }

        // ── Edge-aware refinement via guided filter ──────────────────────
        // The guided filter (He et al. 2010) is a local linear model that
        // transfers edge structure from the guide (original photo) into the
        // matte. Where the photo has a strong luminance edge (hair strand vs
        // background) the filter preserves or sharpens the matte boundary;
        // in smooth regions it acts as an edge-preserving blur.
        //
        // • radius  — neighbourhood size in pixels; 8px covers a few hair
        //             strands without over-smoothing the silhouette.
        // • epsilon — regularisation; small values (1e-4) make the filter
        //             follow guide edges very tightly (good for crisp hair).
        let guided = combined.applyingFilter("CIGuidedFilter", parameters: [
            "inputGuideImage": guide,
            kCIInputRadiusKey: 8.0,
            "inputEpsilon": 0.0001
        ]).cropped(to: extent)

        // Tighten the edge: erode by <1px to kill background-colour bleed,
        // then a gentle blur smooths aliasing, then a contrast curve makes
        // the matte commit (either hair or transparent — no muddy halo).
        let eroded = guided.applyingFilter("CIMorphologyMinimum", parameters: [
            kCIInputRadiusKey: 0.7
        ])
        let blurred = eroded.applyingFilter("CIGaussianBlur", parameters: [
            kCIInputRadiusKey: 0.6
        ])
        let contrast = blurred.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1.15, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1.15, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1.15, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1.15),
            "inputBiasVector": CIVector(x: -0.05, y: -0.05, z: -0.05, w: -0.05)
        ])
        // Clamp to [0,1] — the contrast boost above can push opaque regions
        // above 1.0 (e.g. 1.0*1.15-0.05 = 1.10). Without clamping, that
        // >1.0 matte value flows into CIBlendWithMask and multiplies the
        // original RGB by >1, causing visible overexposure of the cutout.
        let clamped = contrast.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
        ])
        return clamped.cropped(to: extent)
    }

    /// Scales a Vision-produced mask image up to the source image's extent and
    /// pins the result so subsequent filters see a finite, aligned rect.
    private static func scaleMaskToExtent(_ mask: CIImage, extent: CGRect) -> CIImage {
        let sx = extent.width / mask.extent.width
        let sy = extent.height / mask.extent.height
        return mask
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .cropped(to: extent)
    }

    /// Detects the largest face in the image. Returns rect in image pixel coordinates,
    /// origin at TOP-LEFT (Vision returns bottom-left, we flip).
    static func detectFace(in image: CGImage) -> CGRect? {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observations = request.results, !observations.isEmpty else { return nil }

        let imgW = CGFloat(image.width)
        let imgH = CGFloat(image.height)

        // Pick the largest face (most likely the portrait subject).
        let largest = observations.max { lhs, rhs in
            lhs.boundingBox.width * lhs.boundingBox.height
                < rhs.boundingBox.width * rhs.boundingBox.height
        }!

        // Vision uses normalized coordinates with origin bottom-left.
        let bb = largest.boundingBox
        let x = bb.origin.x * imgW
        let w = bb.width * imgW
        let h = bb.height * imgH
        // Flip Y to top-left origin.
        let y = (1.0 - bb.origin.y - bb.height) * imgH
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Detects the lowest visible body joint using Vision body-pose estimation.
    /// Returns Y in image pixel coordinates (top-left origin), or nil if no pose found.
    static func detectBodyPoseBottom(in image: CGImage) -> CGFloat? {
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return nil }

        guard let observation = request.results?.first else { return nil }
        let imgH = CGFloat(image.height)
        var lowestY: CGFloat = 0

        for jointName in observation.availableJointNames {
            guard let point = try? observation.recognizedPoint(jointName),
                  point.confidence > 0.1 else { continue }
            // Vision uses normalized coords with bottom-left origin; flip to top-left.
            let y = (1.0 - point.location.y) * imgH
            lowestY = max(lowestY, y)
        }
        return lowestY > 0 ? lowestY : nil
    }

    /// Scans the alpha channel of a cutout image from the bottom up to find the
    /// lowest row containing non-transparent content. Fast zero-copy fallback when
    /// body-pose detection fails (e.g. non-standard pose, back of head).
    static func contentBottomFromAlpha(of image: CGImage) -> CGFloat? {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else { return nil }

        // Render into a known RGBA layout so we can reliably index the alpha byte.
        let bpr = w * 4
        var pixels = [UInt8](repeating: 0, count: h * bpr)
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: bpr,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        let sampleStep = max(1, w / 64)
        for row in stride(from: h - 1, through: 0, by: -1) {
            for col in stride(from: 0, to: w, by: sampleStep) {
                let offset = row * bpr + col * 4 + 3 // alpha = last byte in RGBA
                if pixels[offset] > 20 {
                    return CGFloat(row)
                }
            }
        }
        return nil
    }

    // MARK: - Face + Eye Landmark Detection

    /// Detects the largest face **and** eye-landmark positions in a single Vision
    /// pass using `VNDetectFaceLandmarksRequest`.  Returns nil when no face is
    /// found at all; `eyeCenter`/`interEyeDistance` are nil when the eyes
    /// couldn't be located (e.g. face turned away).
    static func detectFaceLandmarks(in image: CGImage) -> FaceDetectionResult? {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observations = request.results, !observations.isEmpty else { return nil }

        let imgW = CGFloat(image.width)
        let imgH = CGFloat(image.height)

        // Pick the largest face (most likely the portrait subject).
        let largest = observations.max { lhs, rhs in
            lhs.boundingBox.width * lhs.boundingBox.height
                < rhs.boundingBox.width * rhs.boundingBox.height
        }!

        // --- Face bounding box (same conversion as detectFace) ---
        let bb = largest.boundingBox
        let faceX = bb.origin.x * imgW
        let faceW = bb.width   * imgW
        let faceH = bb.height  * imgH
        let faceY = (1.0 - bb.origin.y - bb.height) * imgH
        let faceRect = CGRect(x: faceX, y: faceY, width: faceW, height: faceH)

        // --- Eye landmarks ---
        guard let landmarks = largest.landmarks else {
            return FaceDetectionResult(faceRect: faceRect, eyeCenter: nil, interEyeDistance: nil)
        }

        // Centroid of a landmark region → image pixels (top-left origin).
        // Landmark points are normalised to the face bounding box with origin
        // at bottom-left, matching Vision's coordinate convention.
        func regionCenter(_ region: VNFaceLandmarkRegion2D?) -> CGPoint? {
            guard let region, region.pointCount > 0 else { return nil }
            let pts = region.normalizedPoints
            var sumX: CGFloat = 0, sumY: CGFloat = 0
            for i in 0..<region.pointCount {
                sumX += pts[i].x
                sumY += pts[i].y
            }
            let avgX = sumX / CGFloat(region.pointCount)
            let avgY = sumY / CGFloat(region.pointCount)
            let px = (bb.origin.x + avgX * bb.width)  * imgW
            let py = (1.0 - (bb.origin.y + avgY * bb.height)) * imgH
            return CGPoint(x: px, y: py)
        }

        // Prefer pupils (single point, most precise); fall back to eye-region centroids.
        let leftCenter  = regionCenter(landmarks.leftPupil)  ?? regionCenter(landmarks.leftEye)
        let rightCenter = regionCenter(landmarks.rightPupil) ?? regionCenter(landmarks.rightEye)

        guard let left = leftCenter, let right = rightCenter else {
            return FaceDetectionResult(faceRect: faceRect, eyeCenter: nil, interEyeDistance: nil)
        }

        let eyeCenter = CGPoint(x: (left.x + right.x) / 2,
                                y: (left.y + right.y) / 2)
        let dx = right.x - left.x
        let dy = right.y - left.y
        let ied = sqrt(dx * dx + dy * dy)

        return FaceDetectionResult(faceRect: faceRect, eyeCenter: eyeCenter, interEyeDistance: ied)
    }

    // MARK: - BiRefNet (advanced hair matting)

    /// Removes the background using a BiRefNet CoreML model. Produces a true
    /// alpha matte (0.0–1.0 per pixel) rather than the semi-binary mask that
    /// Apple's Vision pipeline yields. Much better for fine hair strands.
    ///
    /// Falls back to `subjectLift()` when the model fails to produce output.
    static func birefnetLift(image: CGImage, model: MLModel) throws -> CGImage {
        let originalCI = CIImage(cgImage: image)
        let extent = originalCI.extent

        // BiRefNet expects 1024×1024 input — resize, run inference, scale back.
        let modelSize = 1024
        let inputSize = CGSize(width: modelSize, height: modelSize)

        // Resize to model input using CIImage (GPU-accelerated).
        let scaleX = CGFloat(modelSize) / extent.width
        let scaleY = CGFloat(modelSize) / extent.height
        let resized = originalCI
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .cropped(to: CGRect(origin: .zero, size: inputSize))

        // Render to a pixel buffer for CoreML input.
        guard let inputBuffer = createPixelBuffer(from: resized, size: inputSize) else {
            print("[BiRefNet] Failed to create input buffer, falling back to Vision")
            return try subjectLift(image: image)
        }

        // Run CoreML inference.
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "input": MLFeatureValue(pixelBuffer: inputBuffer)
        ])

        let prediction: MLFeatureProvider
        do {
            prediction = try model.prediction(from: input)
        } catch {
            print("[BiRefNet] Inference failed: \(error), falling back to Vision")
            return try subjectLift(image: image)
        }

        // Extract the output mask. BiRefNet outputs a single-channel alpha matte.
        // The CoreML model may return an image (CVPixelBuffer) or a tensor
        // (MLMultiArray) depending on how it was converted. We handle both.
        let outputNames = ["output", "sigmoid_output", "out"]
        var maskCI: CIImage?

        // Strategy 1: Try CVPixelBuffer output (ImageType in CoreML spec).
        for name in outputNames {
            if let feature = prediction.featureValue(for: name),
               let buffer = feature.imageBufferValue {
                maskCI = CIImage(cvPixelBuffer: buffer)
                print("[BiRefNet] Got image output for '\(name)'")
                break
            }
        }
        if maskCI == nil {
            for name in prediction.featureNames {
                if let feature = prediction.featureValue(for: name),
                   let buffer = feature.imageBufferValue {
                    maskCI = CIImage(cvPixelBuffer: buffer)
                    print("[BiRefNet] Got image output for '\(name)' (scan)")
                    break
                }
            }
        }

        // Strategy 2: Fall back to MLMultiArray output (tensor).
        if maskCI == nil {
            maskCI = extractMaskFromMultiArray(prediction: prediction)
        }

        guard let rawMask = maskCI else {
            print("[BiRefNet] No output mask found, falling back to Vision")
            return try subjectLift(image: image)
        }

        // Scale the mask to the original image resolution.
        let mask = scaleMaskToExtent(rawMask, extent: extent)

        // Apply guided filter for edge refinement using the original as guide.
        let guided = mask.applyingFilter("CIGuidedFilter", parameters: [
            "inputGuideImage": originalCI,
            kCIInputRadiusKey: 6.0,
            "inputEpsilon": 0.0002
        ]).cropped(to: extent)

        // Tighten the edge: erode by <1px to kill background-colour bleed,
        // then a gentle blur smooths aliasing, then a contrast curve makes
        // the matte commit (either hair or transparent — no muddy halo).
        // Mirrors the refinement in refineAlphaMatte() for the Vision path.
        let eroded = guided.applyingFilter("CIMorphologyMinimum", parameters: [
            kCIInputRadiusKey: 0.7
        ])
        let blurred = eroded.applyingFilter("CIGaussianBlur", parameters: [
            kCIInputRadiusKey: 0.6
        ])
        let contrast = blurred.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1.15, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1.15, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1.15, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1.15),
            "inputBiasVector": CIVector(x: -0.05, y: -0.05, z: -0.05, w: -0.05)
        ])
        let refined = contrast.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
        ]).cropped(to: extent)

        // Composite: original RGB + BiRefNet alpha matte.
        let clearBG = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
            .cropped(to: extent)
        let composed = originalCI.applyingFilter("CIBlendWithMask", parameters: [
            "inputBackgroundImage": clearBG,
            "inputMaskImage": refined
        ]).cropped(to: extent)

        let outputCS = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let cg = ciContext.createCGImage(composed, from: extent, format: .RGBA8, colorSpace: outputCS) else {
            print("[BiRefNet] CGImage creation failed, falling back to Vision")
            return try subjectLift(image: image)
        }
        return cg
    }

    /// Extracts a grayscale mask CIImage from the first MLMultiArray output
    /// found in the prediction. Handles shapes like (1,1,H,W), (1,H,W), or (H,W)
    /// and both Float32 and Float16 data types.
    private static func extractMaskFromMultiArray(prediction: MLFeatureProvider) -> CIImage? {
        for name in prediction.featureNames {
            guard let feature = prediction.featureValue(for: name),
                  let multiArray = feature.multiArrayValue else { continue }

            let shape = multiArray.shape.map { $0.intValue }
            guard shape.count >= 2 else { continue }

            let h = shape[shape.count - 2]
            let w = shape[shape.count - 1]
            let count = w * h
            guard count > 0 else { continue }

            // Convert the tensor values to 8-bit grayscale bytes.
            var bytes = [UInt8](repeating: 0, count: count)
            let ptr = multiArray.dataPointer

            switch multiArray.dataType {
            case .float32:
                let fp = ptr.assumingMemoryBound(to: Float.self)
                for i in 0..<count {
                    bytes[i] = UInt8(min(255, max(0, fp[i] * 255)))
                }
            case .float16:
                // Float16 is stored as UInt16 bit pattern.
                let fp = ptr.assumingMemoryBound(to: UInt16.self)
                for i in 0..<count {
                    let f = Float(Float16(bitPattern: fp[i]))
                    bytes[i] = UInt8(min(255, max(0, f * 255)))
                }
            default:
                print("[BiRefNet] Unsupported MultiArray data type: \(multiArray.dataType)")
                continue
            }

            guard let provider = CGDataProvider(data: Data(bytes) as CFData),
                  let cgMask = CGImage(
                      width: w, height: h,
                      bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                      space: CGColorSpaceCreateDeviceGray(),
                      bitmapInfo: CGBitmapInfo(rawValue: 0),
                      provider: provider, decode: nil,
                      shouldInterpolate: false, intent: .defaultIntent) else {
                continue
            }

            print("[BiRefNet] Got MultiArray output for '\(name)' shape=\(shape)")
            return CIImage(cgImage: cgMask)
        }
        return nil
    }

    /// Creates a CVPixelBuffer from a CIImage at the specified size.
    private static func createPixelBuffer(from image: CIImage, size: CGSize) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width), Int(size.height),
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let pb = buffer else { return nil }
        ciContext.render(image, to: pb)
        return pb
    }

    // MARK: - Process pipeline

    /// Convenience: lift subject, detect face + eyes, and measure body extent.
    /// When a BiRefNet model is provided, uses the advanced pipeline for better
    /// hair quality; otherwise falls back to the Apple Vision pipeline.
    static func process(image: CGImage, birefnetModel: MLModel? = nil) throws -> ProcessedSubject {
        let cutout: CGImage
        if let model = birefnetModel {
            cutout = try birefnetLift(image: image, model: model)
            print("[Process] Used BiRefNet pipeline")
        } else {
            cutout = try subjectLift(image: image)
            print("[Process] Used Apple Vision pipeline")
        }
        // Detect on the original image (better signal than masked cutout);
        // coordinates remain valid because the cutout has the same dimensions.
        let faceResult = detectFaceLandmarks(in: image)
        // Body bottom: prefer body-pose joints, fall back to alpha scan.
        let bodyBottom = detectBodyPoseBottom(in: image)
            ?? contentBottomFromAlpha(of: cutout)
            ?? CGFloat(cutout.height)
        return ProcessedSubject(
            cutout: cutout,
            faceRect: faceResult?.faceRect,
            eyeCenter: faceResult?.eyeCenter,
            interEyeDistance: faceResult?.interEyeDistance,
            bodyBottomY: bodyBottom
        )
    }

    // MARK: - Helpers

    /// Loads a CGImage from raw file data, applying any EXIF orientation so the
    /// image is upright. Without this iPhone/Android portraits often appear sideways.
    static func cgImage(from data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return loadOriented(source: src)
    }

    static func cgImage(from url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return loadOriented(source: src)
    }

    private static func loadOriented(source: CGImageSource) -> CGImage? {
        guard let raw = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientationRaw = (props?[kCGImagePropertyOrientation] as? UInt32) ?? 1
        if orientationRaw == 1 { return raw } // already upright
        guard let cgOrientation = CGImagePropertyOrientation(rawValue: orientationRaw) else { return raw }
        // If orientation correction fails, return the raw image rather than nil —
        // a sideways portrait is better than no portrait at all.
        return applyOrientation(raw, orientation: cgOrientation) ?? raw
    }

    private static func applyOrientation(_ image: CGImage, orientation: CGImagePropertyOrientation) -> CGImage? {
        let ciImage = CIImage(cgImage: image).oriented(orientation)
        let outputCS = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return ciContext.createCGImage(ciImage, from: ciImage.extent, format: .RGBA8, colorSpace: outputCS)
    }

    static func pngData(from image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Upscale

    /// Upscales a CGImage by the given factor using high-quality Lanczos
    /// interpolation, followed by luminance sharpening to recover detail
    /// and light noise reduction to suppress interpolation artefacts.
    /// Returns nil only when the Core Image filter chain fails.
    static func upscale(image: CGImage, factor: CGFloat = 2.0) -> CGImage? {
        let source = CIImage(cgImage: image)

        // 1. CILanczosScaleTransform — best-quality resampling in Core Image.
        let lanczos = CIFilter.lanczosScaleTransform()
        lanczos.inputImage = source
        lanczos.scale = Float(factor)
        lanczos.aspectRatio = 1.0
        guard let scaled = lanczos.outputImage else { return nil }

        // 2. CISharpenLuminance — counteract the slight softening that
        //    interpolation introduces without amplifying colour noise.
        let sharpen = CIFilter.sharpenLuminance()
        sharpen.inputImage = scaled
        sharpen.sharpness = 0.4
        sharpen.radius = 1.5
        guard let sharpened = sharpen.outputImage else { return nil }

        // 3. CINoiseReduction — clean up faint ringing artefacts that Lanczos
        //    can produce in smooth gradients (skin, out-of-focus areas).
        let denoise = CIFilter.noiseReduction()
        denoise.inputImage = sharpened
        denoise.noiseLevel = 0.01
        denoise.sharpness = 0.3
        guard let denoised = denoise.outputImage else { return nil }

        let outputCS = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return ciContext.createCGImage(denoised, from: denoised.extent, format: .RGBA8, colorSpace: outputCS)
    }

    // MARK: - Magic Retouch

    /// One-click studio-quality enhancement for a cutout CGImage.
    /// Combines Apple's built-in auto-adjustment analysis with a curated
    /// chain of subtle studio polish filters. Works best on cutout images
    /// (subject on transparent background) because the analysis focuses
    /// on the person, not background noise.
    static func magicRetouch(image: CGImage) -> CGImage? {
        let source = CIImage(cgImage: image)
        let extent = source.extent
        var current = source

        // 1. Apple auto-adjustment — analyses the image and returns optimal
        //    CIFilter corrections (face balance, vibrance, tone curve, etc.).
        //    Red-eye correction disabled since cutouts have no flash red-eye.
        let options: [CIImageAutoAdjustmentOption: Any] = [
            .redEye: false
        ]
        let autoFilters = source.autoAdjustmentFilters(options: options)
        for filter in autoFilters {
            filter.setValue(current, forKey: kCIInputImageKey)
            if let out = filter.outputImage {
                current = out
            }
        }

        // 2. CIVibrance — smart saturation that boosts muted tones (common
        //    in office lighting) without over-saturating vivid colours.
        let vibrance = CIFilter.vibrance()
        vibrance.inputImage = current
        vibrance.amount = 0.3
        if let out = vibrance.outputImage { current = out }

        // 3. CIHighlightShadowAdjust — subtle shadow lift to open up
        //    under-chin and under-brow areas from harsh office lighting.
        let hlShadow = CIFilter.highlightShadowAdjust()
        hlShadow.inputImage = current
        hlShadow.shadowAmount = 0.15
        hlShadow.highlightAmount = 1.0
        if let out = hlShadow.outputImage { current = out }

        // 4. CITemperatureAndTint — gentle warmth (+200K) to shift from
        //    cool fluorescent tones towards a warm studio feel.
        let temp = CIFilter.temperatureAndTint()
        temp.inputImage = current
        temp.neutral = CIVector(x: 6500, y: 0)
        temp.targetNeutral = CIVector(x: 6700, y: 0)
        if let out = temp.outputImage { current = out }

        // 5. CISharpenLuminance — micro-contrast for perceived crispness
        //    (lighter than the upscale chain since this is native resolution).
        let sharpen = CIFilter.sharpenLuminance()
        sharpen.inputImage = current
        sharpen.sharpness = 0.25
        sharpen.radius = 1.0
        if let out = sharpen.outputImage { current = out }

        let outputCS = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return ciContext.createCGImage(current.cropped(to: extent), from: extent, format: .RGBA8, colorSpace: outputCS)
    }
}
