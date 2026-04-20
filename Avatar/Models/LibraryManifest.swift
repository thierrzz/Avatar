import Foundation

// MARK: - Archive manifest

struct LibraryManifest: Codable {
    let formatVersion: Int
    let appVersion: String
    let createdAt: Date
    let portraitCount: Int
    let backgroundCount: Int
    let presetCount: Int
    let checksums: [String: String]

    static let currentFormatVersion = 1
}

// MARK: - Portrait DTO

struct PortraitDTO: Codable {
    let id: UUID
    let name: String
    let tags: String
    let createdAt: Date
    let updatedAt: Date

    // Face detection
    let faceRectX: Double
    let faceRectY: Double
    let faceRectW: Double
    let faceRectH: Double
    let eyeCenterX: Double
    let eyeCenterY: Double
    let interEyeDistance: Double
    let bodyBottomY: Double

    // Canvas transform
    let offsetX: Double
    let offsetY: Double
    let scale: Double

    // Background link
    let backgroundPresetID: UUID?

    // Image adjustments
    let adjExposure: Double
    let adjContrast: Double
    let adjBrightness: Double
    let adjSaturation: Double
    let adjHue: Double
    let adjTemperature: Double
    let adjTint: Double
    let adjHighlights: Double
    let adjShadows: Double
    let adjWhites: Double
    let adjBlacks: Double

    // Flags
    let isUpscaled: Bool
    let isMagicRetouched: Bool

    // Which image files are present in the archive
    let hasOriginal: Bool
    let hasCutout: Bool
    let hasPreRetouch: Bool
}

extension PortraitDTO {
    init(from portrait: Portrait) {
        self.id = portrait.id
        self.name = portrait.name
        self.tags = portrait.tags
        self.createdAt = portrait.createdAt
        self.updatedAt = portrait.updatedAt
        self.faceRectX = portrait.faceRectX
        self.faceRectY = portrait.faceRectY
        self.faceRectW = portrait.faceRectW
        self.faceRectH = portrait.faceRectH
        self.eyeCenterX = portrait.eyeCenterX
        self.eyeCenterY = portrait.eyeCenterY
        self.interEyeDistance = portrait.interEyeDistance
        self.bodyBottomY = portrait.bodyBottomY
        self.offsetX = portrait.offsetX
        self.offsetY = portrait.offsetY
        self.scale = portrait.scale
        self.backgroundPresetID = portrait.backgroundPresetID
        self.adjExposure = portrait.adjExposure
        self.adjContrast = portrait.adjContrast
        self.adjBrightness = portrait.adjBrightness
        self.adjSaturation = portrait.adjSaturation
        self.adjHue = portrait.adjHue
        self.adjTemperature = portrait.adjTemperature
        self.adjTint = portrait.adjTint
        self.adjHighlights = portrait.adjHighlights
        self.adjShadows = portrait.adjShadows
        self.adjWhites = portrait.adjWhites
        self.adjBlacks = portrait.adjBlacks
        self.isUpscaled = portrait.isUpscaled
        self.isMagicRetouched = portrait.isMagicRetouched
        self.hasOriginal = portrait.originalImageData != nil
        self.hasCutout = portrait.cutoutPNG != nil
        self.hasPreRetouch = portrait.preRetouchPNG != nil
    }

    func applyTo(_ portrait: Portrait) {
        portrait.name = name
        portrait.tags = tags
        portrait.createdAt = createdAt
        portrait.updatedAt = updatedAt
        portrait.faceRectX = faceRectX
        portrait.faceRectY = faceRectY
        portrait.faceRectW = faceRectW
        portrait.faceRectH = faceRectH
        portrait.eyeCenterX = eyeCenterX
        portrait.eyeCenterY = eyeCenterY
        portrait.interEyeDistance = interEyeDistance
        portrait.bodyBottomY = bodyBottomY
        portrait.offsetX = offsetX
        portrait.offsetY = offsetY
        portrait.scale = scale
        portrait.backgroundPresetID = backgroundPresetID
        portrait.adjExposure = adjExposure
        portrait.adjContrast = adjContrast
        portrait.adjBrightness = adjBrightness
        portrait.adjSaturation = adjSaturation
        portrait.adjHue = adjHue
        portrait.adjTemperature = adjTemperature
        portrait.adjTint = adjTint
        portrait.adjHighlights = adjHighlights
        portrait.adjShadows = adjShadows
        portrait.adjWhites = adjWhites
        portrait.adjBlacks = adjBlacks
        portrait.isUpscaled = isUpscaled
        portrait.isMagicRetouched = isMagicRetouched
    }
}

// MARK: - Background DTO

struct BackgroundPresetDTO: Codable {
    let id: UUID
    let name: String
    let kind: String
    let colorR: Double
    let colorG: Double
    let colorB: Double
    let colorA: Double
    let isDefault: Bool
    let createdAt: Date
    let hasImage: Bool
}

extension BackgroundPresetDTO {
    init(from bg: BackgroundPreset) {
        self.id = bg.id
        self.name = bg.name
        self.kind = bg.kindRaw
        self.colorR = bg.colorR
        self.colorG = bg.colorG
        self.colorB = bg.colorB
        self.colorA = bg.colorA
        self.isDefault = bg.isDefault
        self.createdAt = bg.createdAt
        self.hasImage = bg.imageData != nil
    }

    func toModel(imageData: Data?) -> BackgroundPreset {
        let bgKind = BackgroundKind(rawValue: kind) ?? .color
        let preset = BackgroundPreset(
            id: id,
            name: name,
            kind: bgKind,
            imageData: imageData,
            color: (colorR, colorG, colorB, colorA),
            isDefault: isDefault
        )
        return preset
    }
}

// MARK: - Export preset DTO

struct ExportPresetDTO: Codable {
    let id: UUID
    let name: String
    let width: Int
    let height: Int
    let shape: String
    let isBuiltIn: Bool
    let sortOrder: Int
}

extension ExportPresetDTO {
    init(from preset: ExportPreset) {
        self.id = preset.id
        self.name = preset.name
        self.width = preset.width
        self.height = preset.height
        self.shape = preset.shapeRaw
        self.isBuiltIn = preset.isBuiltIn
        self.sortOrder = preset.sortOrder
    }

    func toModel() -> ExportPreset {
        ExportPreset(
            id: id,
            name: name,
            width: width,
            height: height,
            shape: ExportShape(rawValue: shape) ?? .square,
            isBuiltIn: isBuiltIn,
            sortOrder: sortOrder
        )
    }
}
