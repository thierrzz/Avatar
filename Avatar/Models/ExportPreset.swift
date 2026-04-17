import Foundation
import SwiftData

enum ExportShape: String, Codable, CaseIterable, Identifiable {
    case square
    case circle
    var id: String { rawValue }
    var label: String { self == .square ? Loc.square : Loc.circle }
}

@Model
final class ExportPreset {
    @Attribute(.unique) var id: UUID
    var name: String
    var width: Int
    var height: Int
    var shapeRaw: String
    var isBuiltIn: Bool
    var sortOrder: Int

    init(
        id: UUID = UUID(),
        name: String,
        width: Int,
        height: Int,
        shape: ExportShape,
        isBuiltIn: Bool = false,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
        self.shapeRaw = shape.rawValue
        self.isBuiltIn = isBuiltIn
        self.sortOrder = sortOrder
    }

    var shape: ExportShape {
        get { ExportShape(rawValue: shapeRaw) ?? .square }
        set { shapeRaw = newValue.rawValue }
    }
}
