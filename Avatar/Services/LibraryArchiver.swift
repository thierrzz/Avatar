import Foundation
import SwiftData
import CryptoKit
import ZIPFoundation

enum LibraryArchiverError: LocalizedError {
    case noPortraitsSelected
    case archiveCreationFailed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noPortraitsSelected: return "No portraits selected for export."
        case .archiveCreationFailed: return "Failed to create the library archive."
        case .cancelled: return "Export was cancelled."
        }
    }
}

@MainActor
final class LibraryArchiver {

    struct ExportOptions {
        var portraitIDs: Set<UUID>?      // nil = all
        var includeBackgrounds: Bool = true
        var includeExportPresets: Bool = true
    }

    /// Estimated total byte size for the given portraits (for UI display).
    static func estimateSize(
        portraits: [Portrait],
        backgrounds: [BackgroundPreset],
        includeBackgrounds: Bool,
        includeExportPresets: Bool
    ) -> Int64 {
        var total: Int64 = 0
        for p in portraits {
            total += Int64(p.originalImageData?.count ?? 0)
            total += Int64(p.cutoutPNG?.count ?? 0)
            total += Int64(p.preRetouchPNG?.count ?? 0)
        }
        if includeBackgrounds {
            for bg in backgrounds {
                total += Int64(bg.imageData?.count ?? 0)
            }
        }
        return total
    }

    /// Exports the library to a `.avatarlib` ZIP archive at the given URL.
    /// Progress is reported as a fraction 0...1.
    static func export(
        to url: URL,
        options: ExportOptions,
        context: ModelContext,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws {
        // 1. Fetch data on main actor
        let allPortraits = try context.fetch(FetchDescriptor<Portrait>())
        let portraits: [Portrait]
        if let ids = options.portraitIDs {
            guard !ids.isEmpty else { throw LibraryArchiverError.noPortraitsSelected }
            portraits = allPortraits.filter { ids.contains($0.id) }
        } else {
            portraits = allPortraits
        }
        guard !portraits.isEmpty else { throw LibraryArchiverError.noPortraitsSelected }

        let allBackgrounds = try context.fetch(FetchDescriptor<BackgroundPreset>())
        let backgrounds = options.includeBackgrounds ? allBackgrounds : []

        let allPresets = try context.fetch(FetchDescriptor<ExportPreset>())
        let presets = options.includeExportPresets ? allPresets.filter { !$0.isBuiltIn } : []

        // 2. Build DTOs and collect image data blobs (snapshot on main actor)
        let portraitEntries: [(dto: PortraitDTO, original: Data?, cutout: Data?, preRetouch: Data?)] =
            portraits.map { p in
                (PortraitDTO(from: p), p.originalImageData, p.cutoutPNG, p.preRetouchPNG)
            }
        let backgroundEntries: [(dto: BackgroundPresetDTO, imageData: Data?)] =
            backgrounds.map { bg in (BackgroundPresetDTO(from: bg), bg.imageData) }
        let presetDTOs = presets.map { ExportPresetDTO(from: $0) }

        let totalEntries = portraits.count + backgrounds.count + presets.count + 1 // +1 for manifest
        var completedEntries = 0

        // 3. Build archive on background thread
        try await Task.detached {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("avatarlib")

            let archive: Archive
            do {
                archive = try Archive(url: tempURL, accessMode: .create)
            } catch {
                throw LibraryArchiverError.archiveCreationFailed
            }

            var checksums: [String: String] = [:]

            // Helper: add data entry with optional checksum
            func addEntry(path: String, data: Data, compress: Bool) throws {
                try archive.addEntry(
                    with: path,
                    type: .file,
                    uncompressedSize: Int64(data.count),
                    compressionMethod: compress ? .deflate : .none,
                    provider: { position, size in
                        data[Int(position) ..< Int(position) + size]
                    }
                )
            }

            func sha256(_ data: Data) -> String {
                let digest = SHA256.hash(data: data)
                return digest.map { String(format: "%02x", $0) }.joined()
            }

            // 3a. Portraits
            for entry in portraitEntries {
                try Task.checkCancellation()

                let dir = "portraits/\(entry.dto.id.uuidString)"
                let metaData = try encoder.encode(entry.dto)
                try addEntry(path: "\(dir)/metadata.json", data: metaData, compress: true)

                if let original = entry.original {
                    let path = "\(dir)/original.dat"
                    checksums[path] = sha256(original)
                    try addEntry(path: path, data: original, compress: false)
                }
                if let cutout = entry.cutout {
                    let path = "\(dir)/cutout.png"
                    checksums[path] = sha256(cutout)
                    try addEntry(path: path, data: cutout, compress: false)
                }
                if let preRetouch = entry.preRetouch {
                    let path = "\(dir)/pre-retouch.png"
                    checksums[path] = sha256(preRetouch)
                    try addEntry(path: path, data: preRetouch, compress: false)
                }

                completedEntries += 1
                let frac = Double(completedEntries) / Double(totalEntries)
                await MainActor.run { progress(frac) }
            }

            // 3b. Backgrounds
            for entry in backgroundEntries {
                try Task.checkCancellation()

                let dir = "backgrounds/\(entry.dto.id.uuidString)"
                let metaData = try encoder.encode(entry.dto)
                try addEntry(path: "\(dir)/metadata.json", data: metaData, compress: true)

                if let imgData = entry.imageData {
                    let path = "\(dir)/image.dat"
                    checksums[path] = sha256(imgData)
                    try addEntry(path: path, data: imgData, compress: false)
                }

                completedEntries += 1
                let frac = Double(completedEntries) / Double(totalEntries)
                await MainActor.run { progress(frac) }
            }

            // 3c. Export presets
            for dto in presetDTOs {
                try Task.checkCancellation()

                let data = try encoder.encode(dto)
                try addEntry(path: "presets/\(dto.id.uuidString).json", data: data, compress: true)

                completedEntries += 1
                let frac = Double(completedEntries) / Double(totalEntries)
                await MainActor.run { progress(frac) }
            }

            // 3d. Manifest (written last so checksums are complete)
            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
            let manifest = LibraryManifest(
                formatVersion: LibraryManifest.currentFormatVersion,
                appVersion: appVersion,
                createdAt: Date(),
                portraitCount: portraitEntries.count,
                backgroundCount: backgroundEntries.count,
                presetCount: presetDTOs.count,
                checksums: checksums
            )
            let manifestData = try encoder.encode(manifest)
            try addEntry(path: "manifest.json", data: manifestData, compress: true)

            completedEntries += 1
            await MainActor.run { progress(1.0) }

            // 4. Move temp file to final destination
            let fm = FileManager.default
            if fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
            }
            try fm.moveItem(at: tempURL, to: url)
        }.value
    }
}
