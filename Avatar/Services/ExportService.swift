import Foundation
import AppKit
import UniformTypeIdentifiers

enum ExportError: Error {
    case writeFailed
    case encodingFailed
}

enum ExportService {
    /// Writes a CGImage as PNG (preserving alpha) to the given URL.
    static func writePNG(_ image: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw ExportError.encodingFailed
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ExportError.writeFailed
        }
    }

    /// Builds a filename like "Jan_de_Vries_LinkedIn.png".
    static func filename(for portraitName: String, preset: ExportPreset) -> String {
        let safeName = sanitize(portraitName.isEmpty ? Loc.portrait : portraitName)
        let safePreset = sanitize(preset.name)
        return "\(safeName)_\(safePreset).png"
    }

    private static func sanitize(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return s.unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "_" }
            .reduce(into: "") { $0.append($1) }
    }
}
