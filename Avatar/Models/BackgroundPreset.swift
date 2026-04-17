import Foundation
import SwiftData
import SwiftUI

enum BackgroundKind: String, Codable {
    case image
    case color
}

@Model
final class BackgroundPreset {
    @Attribute(.unique) var id: UUID
    var name: String
    var kindRaw: String
    var isDefault: Bool
    var createdAt: Date

    @Attribute(.externalStorage) var imageData: Data?

    // sRGB components for color kind
    var colorR: Double
    var colorG: Double
    var colorB: Double
    var colorA: Double

    init(
        id: UUID = UUID(),
        name: String,
        kind: BackgroundKind,
        imageData: Data? = nil,
        color: (Double, Double, Double, Double) = (0.94, 0.95, 0.97, 1.0),
        isDefault: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kindRaw = kind.rawValue
        self.imageData = imageData
        self.colorR = color.0
        self.colorG = color.1
        self.colorB = color.2
        self.colorA = color.3
        self.isDefault = isDefault
        self.createdAt = Date()
    }

    var kind: BackgroundKind { BackgroundKind(rawValue: kindRaw) ?? .image }

    var colorComponents: (Double, Double, Double, Double) {
        (colorR, colorG, colorB, colorA)
    }
}
