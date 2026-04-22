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

        // v5 (RVM) expects 1024×576 input (keeps the 16:9 aspect RVM was
        // trained against and fits ANE tile limits). v4 (BiRefNet) was
        // 1024×1024 square. We distort to fit — the mask is scaled back to
        // the source extent in scaleMaskToExtent() and the aspect artefact
        // on the resized internal tensor does not propagate to the output.
        let inputWidth = 1024
        let inputHeight = 576
        let inputSize = CGSize(width: inputWidth, height: inputHeight)

        // Resize to model input using CIImage (GPU-accelerated).
        let scaleX = CGFloat(inputWidth) / extent.width
        let scaleY = CGFloat(inputHeight) / extent.height
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

        // Extract the output mask. Both BiRefNet (v4) and RVM (v5) output a
        // single-channel alpha matte, under different feature names:
        //   - BiRefNet: "output" / "sigmoid_output" / "out"
        //   - RVM:      "pha" (alpha) — "fgr" is foreground RGB, ignored here
        //     (see follow-up to wire it in and skip blur-fusion).
        // We try the known names first, then fall through to a scan.
        let outputNames = ["pha", "output", "sigmoid_output", "out"]
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

        // Apply a light guided-filter pass for hair-fringe refinement. Keep
        // radius small and epsilon loose — an aggressively edge-preserving
        // filter (tiny epsilon) snaps the matte to background color edges
        // and can reinforce leaks when the base matte has any error.
        let guided = mask.applyingFilter("CIGuidedFilter", parameters: [
            "inputGuideImage": originalCI,
            kCIInputRadiusKey: 2.0,
            "inputEpsilon": 0.01
        ]).cropped(to: extent)

        // Synthesise a soft hair fringe without a matting model. The
        // portrait mask is near-bimodal (0 or 1) with a thin stair-step
        // at the silhouette edge — we keep the fully opaque interior
        // (via erosion) and only feather the outer ring (via dilation +
        // blur) so hair gains a photographic falloff but shoulders, face
        // and shirt stay fully opaque when composited over any
        // background. Radii scale with the source resolution so the
        // feather reads consistently on 1024-px previews and 4K imports.
        let longSide = max(extent.width, extent.height)
        let scale = max(1.0, longSide / 1024.0)
        let dilateR = 10.0 * scale
        let erodeR  = 4.0  * scale
        let blurR   = 3.0  * scale

        let outerBand = guided
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: dilateR])
            .cropped(to: extent)
        let innerCore = guided
            .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: erodeR])
            .cropped(to: extent)
        // Ring = outer − inner, marking the pixels we're allowed to feather.
        let ring = outerBand.applyingFilter("CISubtractBlendMode", parameters: [
            kCIInputBackgroundImageKey: innerCore
        ]).cropped(to: extent)
        let feathered = guided
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurR])
            .cropped(to: extent)
        // Inside the ring use the blurred mask; outside it keep the
        // guided (near-bimodal) mask so the body interior stays solid.
        let softened = feathered.applyingFilter("CIBlendWithMask", parameters: [
            "inputBackgroundImage": guided,
            "inputMaskImage": ring
        ]).cropped(to: extent)

        // Recover unmixed foreground RGB before compositing. Without this,
        // hair strands still carry `α·F + (1−α)·B_old` — the original
        // background bleeds through against any new backdrop. Blur-fusion
        // (Forte & Pitié, ICIP 2021; Photoroom's refine_foreground) solves
        // for F using a wide-then-narrow two-pass weighted average. Driven
        // by the pre-feather guided α so strand transitions stay soft.
        let refinedFG = refineForeground(source: originalCI, alpha: guided, extent: extent)

        // Composite: refined foreground RGB + feathered alpha matte.
        let clearBG = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
            .cropped(to: extent)
        let alphaMatte = softened.applyingFilter("CIMaskToAlpha")
        let composed = refinedFG.applyingFilter("CIBlendWithMask", parameters: [
            "inputBackgroundImage": clearBG,
            "inputMaskImage": alphaMatte
        ]).cropped(to: extent)

        let outputCS = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let cg = ciContext.createCGImage(composed, from: extent, format: .RGBA8, colorSpace: outputCS) else {
            print("[BiRefNet] CGImage creation failed, falling back to Vision")
            return try subjectLift(image: image)
        }
        return cg
    }

    // MARK: - Foreground refinement (blur-fusion)

    /// Two-pass blur-fusion foreground estimator (Forte & Pitié, ICIP 2021).
    /// Given the observed image `I = α·F + (1−α)·B` and a soft α matte,
    /// recovers an estimate of the unmixed `F` so the new composite doesn't
    /// carry the old background's colour through semi-transparent strands.
    /// First pass uses a wide kernel to gather long-range colour, the second
    /// a narrow one to recover local detail — same cadence as Photoroom's
    /// `FB_blur_fusion_foreground_estimator_2` and BiRefNet's built-in
    /// `refine_foreground` flag.
    private static func refineForeground(
        source: CIImage, alpha: CIImage, extent: CGRect
    ) -> CIImage {
        let pass1 = blurFusionPass(I: source, F: source, B: source,
                                   alpha: alpha, radius: 90, extent: extent)
        let pass2 = blurFusionPass(I: source, F: pass1.F, B: pass1.B,
                                   alpha: alpha, radius: 6, extent: extent)
        return pass2.F
    }

    /// Single blur-fusion pass. Produces a refined foreground `F` and the
    /// blurred background estimate used as the prior for the next pass.
    private static func blurFusionPass(
        I: CIImage, F: CIImage, B: CIImage, alpha: CIImage,
        radius: Double, extent: CGRect
    ) -> (F: CIImage, B: CIImage) {
        // F·α and B·(1−α) weighted images. Alpha is a grayscale mask so
        // `CIMultiplyCompositing` broadcasts it across the RGB channels.
        let fa = F.applyingFilter("CIMultiplyCompositing", parameters: [
            kCIInputBackgroundImageKey: alpha
        ]).cropped(to: extent)
        let invAlpha = alpha.applyingFilter("CIColorInvert").cropped(to: extent)
        let bInv = B.applyingFilter("CIMultiplyCompositing", parameters: [
            kCIInputBackgroundImageKey: invAlpha
        ]).cropped(to: extent)

        let blur: (CIImage) -> CIImage = { input in
            input.applyingFilter("CIGaussianBlur",
                                 parameters: [kCIInputRadiusKey: radius])
                 .cropped(to: extent)
        }
        let blurredAlpha = blur(alpha)
        let blurredFA    = blur(fa)
        let blurredBInv  = blur(bInv)

        let newF = blurFusionKernel.apply(
            extent: extent,
            arguments: [I, alpha, blurredAlpha, blurredFA, blurredBInv]
        ) ?? F
        let newB = computeBlurredBKernel.apply(
            extent: extent,
            arguments: [blurredAlpha, blurredBInv]
        ) ?? B

        return (newF.cropped(to: extent), newB.cropped(to: extent))
    }

    /// Core of the blur-fusion step: divide the blurred weighted images
    /// back out to get `F_hat`, `B_hat`, then add a correction term so the
    /// result reconstructs the observed `I` at the current α.
    private static let blurFusionKernel: CIColorKernel = {
        let src = """
        kernel vec4 blurFusion(__sample I, __sample alpha,
                               __sample blurredAlpha,
                               __sample blurredFA,
                               __sample blurredBInv) {
            float a   = alpha.r;
            float bA  = blurredAlpha.r;
            float eps = 1e-5;
            vec3 F_hat = blurredFA.rgb   / (bA + eps);
            vec3 B_hat = blurredBInv.rgb / ((1.0 - bA) + eps);
            vec3 F = clamp(F_hat + a * (I.rgb - a * F_hat - (1.0 - a) * B_hat),
                           0.0, 1.0);
            return vec4(F, 1.0);
        }
        """
        guard let kernel = CIColorKernel(source: src) else {
            fatalError("[ImageProcessor] blurFusion kernel failed to compile")
        }
        return kernel
    }()

    /// Computes the blurred background estimate used as the prior for the
    /// next blur-fusion pass.
    private static let computeBlurredBKernel: CIColorKernel = {
        let src = """
        kernel vec4 computeBlurredB(__sample blurredAlpha,
                                    __sample blurredBInv) {
            float eps = 1e-5;
            vec3 B = blurredBInv.rgb / ((1.0 - blurredAlpha.r) + eps);
            return vec4(clamp(B, 0.0, 1.0), 1.0);
        }
        """
        guard let kernel = CIColorKernel(source: src) else {
            fatalError("[ImageProcessor] computeBlurredB kernel failed to compile")
        }
        return kernel
    }()

    /// Decode an IEEE 754 binary16 (half-precision) bit-pattern to Float32.
    /// We roll this by hand because `Float(Float16(bitPattern:))` does not
    /// compile on the x86_64 slice of a universal build — `Float16` on x86_64
    /// lacks the `init(bitPattern:)` overload. Works on any architecture and
    /// handles subnormals, infinities, and NaN.
    @inline(__always)
    private static func float16BitsToFloat(_ bits: UInt16) -> Float {
        let sign = UInt32(bits >> 15) & 0x1
        let exponent = UInt32(bits >> 10) & 0x1F
        let mantissa = UInt32(bits) & 0x3FF
        let f32Sign = sign << 31
        let result: UInt32
        if exponent == 0 {
            if mantissa == 0 {
                result = f32Sign
            } else {
                // Subnormal — normalize the mantissa into a float32 exponent.
                var e: UInt32 = 0
                var m = mantissa
                while (m & 0x400) == 0 {
                    m <<= 1
                    e &+= 1
                }
                let f32Exp = (127 &- 15 &- e &+ 1) << 23
                result = f32Sign | f32Exp | ((m & 0x3FF) << 13)
            }
        } else if exponent == 0x1F {
            // Infinity or NaN — preserve by propagating mantissa bits.
            result = f32Sign | (0xFF << 23) | (mantissa << 13)
        } else {
            let f32Exp = (exponent &+ (127 &- 15)) << 23
            result = f32Sign | f32Exp | (mantissa << 13)
        }
        return Float(bitPattern: result)
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
                // Float16 is stored as UInt16 bit pattern. We decode manually
                // rather than via `Float(Float16(bitPattern:))` because that
                // initializer isn't available when compiling for x86_64 (the
                // universal-build slice), even on Swift 5.9+.
                let fp = ptr.assumingMemoryBound(to: UInt16.self)
                for i in 0..<count {
                    let f = ImageProcessor.float16BitsToFloat(fp[i])
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

    // MARK: - Upscale (AI super-resolution)

    enum UpscaleError: Error {
        case pixelBufferCreationFailed
        case modelInputMissing
        case modelOutputMissing
        case outputPixelBufferInvalid
        case sourceTooLarge
    }

    /// The converted Real-ESRGAN models accept a single fixed 512×512 input
    /// (RRDBNet's pixel-unshuffle forces this — dynamic shapes generate a
    /// rank-6 reshape that Core ML rejects). We fit the source into this
    /// square with aspect-preserving padding, run the model, then crop the
    /// padded region back out of the N× output. Tiling is a follow-up.
    private static let fixedUpscaleInputSize: Int = 512

    /// Runs a Real-ESRGAN super-resolution model on the input image and returns
    /// a CGImage at `factor`× resolution. Throws `UpscaleError` when the model's
    /// I/O doesn't match expectations (logged); the caller surfaces it to the UI.
    ///
    /// Input/output contract (fixed by the `coremltools` conversion):
    /// - Input: single image feature named `input` accepting BGRA8 CVPixelBuffer.
    /// - Output: single image feature named `output` returning BGRA8 CVPixelBuffer
    ///   at `factor`× the input dimensions.
    /// If the converted model uses different feature names we fall back to
    /// whatever the model's description declares, so the code doesn't break
    /// the first time we swap in a differently-named checkpoint.
    static func upscale(image: CGImage, using model: MLModel, factor: Int) throws -> CGImage {
        // 1. Fit source into a fixed SxS square with aspect-preserving padding.
        //    The model only accepts S×S; we crop padding back out of the output.
        let S = fixedUpscaleInputSize
        let srcW = CGFloat(image.width)
        let srcH = CGFloat(image.height)
        let longEdge = max(srcW, srcH)
        let fit = CGFloat(S) / longEdge
        let contentW = Int((srcW * fit).rounded())
        let contentH = Int((srcH * fit).rounded())

        guard let padded = paddedSquare(image: image, contentSize: CGSize(width: contentW, height: contentH), side: S) else {
            throw UpscaleError.sourceTooLarge
        }
        print("[Upscale] source \(image.width)×\(image.height) → \(contentW)×\(contentH) in \(S)² before ML")

        // 2. CGImage → CVPixelBuffer (BGRA8) at the model's expected spec.
        guard let pixelBuffer = makePixelBuffer(from: padded) else {
            throw UpscaleError.pixelBufferCreationFailed
        }

        // 3. Run the model. Discover feature names dynamically so we're robust
        //    to naming differences between the 2× and 4× checkpoints.
        let inputName = model.modelDescription.inputDescriptionsByName.keys.first ?? "input"
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            inputName: MLFeatureValue(pixelBuffer: pixelBuffer)
        ])

        let output = try model.prediction(from: provider)

        // 4. Extract the first image-typed output (PixelBuffer or MLMultiArray).
        let outputName = model.modelDescription.outputDescriptionsByName.keys.first ?? "output"
        guard let feature = output.featureValue(for: outputName) else {
            throw UpscaleError.modelOutputMissing
        }

        let fullOutput: CGImage
        if let buf = feature.imageBufferValue, let cg = cgImage(fromPixelBuffer: buf) {
            fullOutput = cg
        } else if let array = feature.multiArrayValue, let cg = cgImage(fromMultiArray: array) {
            fullOutput = cg
        } else {
            throw UpscaleError.modelOutputMissing
        }

        // 5. Crop out the padded margin so the result matches the source AR at
        //    factor× resolution.
        let cropW = contentW * factor
        let cropH = contentH * factor
        let cropRect = CGRect(x: 0, y: 0, width: cropW, height: cropH)
        guard let cropped = fullOutput.cropping(to: cropRect) else { return fullOutput }
        return cropped
    }

    // MARK: - Pad-to-square helper (for fixed-shape ML input)

    /// Resizes `image` to `contentSize` (Lanczos) and composites it at the
    /// top-left of an `side`×`side` black square. Top-left origin matters:
    /// the caller crops the output with CGRect(0, 0, contentW*factor,
    /// contentH*factor) regardless of aspect ratio, so padding on the right
    /// and bottom keeps that crop correct.
    private static func paddedSquare(image: CGImage, contentSize: CGSize, side: Int) -> CGImage? {
        guard let resized = lanczosResize(image: image, to: contentSize) else { return nil }
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        guard let ctx else { return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        // CGContext origin is bottom-left — draw so the content sits at the top-left.
        let drawY = side - Int(contentSize.height.rounded())
        ctx.draw(resized, in: CGRect(x: 0, y: drawY, width: Int(contentSize.width.rounded()), height: Int(contentSize.height.rounded())))
        return ctx.makeImage()
    }

    // MARK: - Lanczos helper (kept only for pre-ML resize)

    /// Resizes a CGImage to an exact target size using Lanczos interpolation.
    /// Used to fit oversized inputs before running the super-resolution model.
    private static func lanczosResize(image: CGImage, to size: CGSize) -> CGImage? {
        let source = CIImage(cgImage: image)
        let sx = size.width / CGFloat(image.width)
        let sy = size.height / CGFloat(image.height)
        let scale = min(sx, sy)
        let aspect = sx / sy

        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = source
        filter.scale = Float(scale)
        filter.aspectRatio = Float(aspect)
        guard let out = filter.outputImage else { return nil }
        let cs = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return ciContext.createCGImage(out, from: out.extent, format: .RGBA8, colorSpace: cs)
    }

    // MARK: - CVPixelBuffer conversion

    /// Creates a BGRA8 CVPixelBuffer from a CGImage. BGRA8 is the format most
    /// `coremltools`-converted image inputs expect, and it's what `CIContext.render`
    /// writes natively without an extra colour conversion step.
    private static func makePixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        let width = image.width
        let height = image.height
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width, height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer = buffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let ctx = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: cs,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelBuffer
    }

    /// Converts a BGRA CVPixelBuffer returned by a Core ML image output to a CGImage.
    private static func cgImage(fromPixelBuffer pb: CVPixelBuffer) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: pb)
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return ciContext.createCGImage(ciImage, from: ciImage.extent, format: .RGBA8, colorSpace: cs)
    }

    /// Fallback path for converted models that emit a float MLMultiArray in
    /// shape [C=3, H, W] with values in [0,1]. Real-ESRGAN outputs this shape
    /// when the CoreML conversion treats output as a tensor rather than an
    /// image feature. Writes RGB bytes into an RGBA8 buffer with alpha=255.
    private static func cgImage(fromMultiArray array: MLMultiArray) -> CGImage? {
        let shape = array.shape.map { $0.intValue }
        // Expect [C, H, W] or [1, C, H, W]. Find the last three dims.
        guard shape.count >= 3 else { return nil }
        let last3 = shape.suffix(3)
        let channels = last3[last3.startIndex]
        let height = last3[last3.startIndex + 1]
        let width = last3[last3.startIndex + 2]
        guard channels == 3, width > 0, height > 0 else { return nil }

        // Strides per element (in logical units of dataType).
        let strides = array.strides.map { $0.intValue }
        let last3Strides = strides.suffix(3)
        let cStride = last3Strides[last3Strides.startIndex]
        let hStride = last3Strides[last3Strides.startIndex + 1]
        let wStride = last3Strides[last3Strides.startIndex + 2]

        let pixelCount = width * height
        var bytes = [UInt8](repeating: 0, count: pixelCount * 4)

        let pointer = array.dataPointer

        @inline(__always) func byte(_ v: Float) -> UInt8 {
            let clamped = max(0, min(1, v))
            return UInt8(clamped * 255)
        }

        switch array.dataType {
        case .float32:
            let base = pointer.bindMemory(to: Float.self, capacity: array.count)
            for y in 0..<height {
                for x in 0..<width {
                    let r = base[0 * cStride + y * hStride + x * wStride]
                    let g = base[1 * cStride + y * hStride + x * wStride]
                    let b = base[2 * cStride + y * hStride + x * wStride]
                    let idx = (y * width + x) * 4
                    bytes[idx + 0] = byte(r)
                    bytes[idx + 1] = byte(g)
                    bytes[idx + 2] = byte(b)
                    bytes[idx + 3] = 255
                }
            }
        case .float16:
            // Read Float16 as UInt16 bit-patterns and widen via a manual
            // decoder — `Float(Float16(bitPattern:))` does not compile on
            // the x86_64 slice of a universal build.
            let base = pointer.bindMemory(to: UInt16.self, capacity: array.count)
            for y in 0..<height {
                for x in 0..<width {
                    let r = ImageProcessor.float16BitsToFloat(base[0 * cStride + y * hStride + x * wStride])
                    let g = ImageProcessor.float16BitsToFloat(base[1 * cStride + y * hStride + x * wStride])
                    let b = ImageProcessor.float16BitsToFloat(base[2 * cStride + y * hStride + x * wStride])
                    let idx = (y * width + x) * 4
                    bytes[idx + 0] = byte(r)
                    bytes[idx + 1] = byte(g)
                    bytes[idx + 2] = byte(b)
                    bytes[idx + 3] = 255
                }
            }
        default:
            return nil
        }

        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
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
