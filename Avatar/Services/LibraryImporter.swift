import Foundation
import SwiftData
import CryptoKit
import ZIPFoundation

// MARK: - Types

enum ImportConflictStrategy: String, CaseIterable, Identifiable {
    case skip     // Only import items that don't exist locally
    case replace  // Overwrite existing items with imported ones
    case copy     // Import as new items with fresh UUIDs

    var id: String { rawValue }

    var label: String {
        switch self {
        case .skip: return Loc.importSkip
        case .replace: return Loc.importReplace
        case .copy: return Loc.importCopy
        }
    }
}

struct ImportPreview {
    let manifest: LibraryManifest
    let portraitCount: Int
    let backgroundCount: Int
    let presetCount: Int
    let conflictingPortraitIDs: Set<UUID>
    let conflictingBackgroundIDs: Set<UUID>
    var hasConflicts: Bool { !conflictingPortraitIDs.isEmpty || !conflictingBackgroundIDs.isEmpty }
}

struct ImportResult {
    let portraitsImported: Int
    let backgroundsImported: Int
    let presetsImported: Int
    let skipped: Int
    let errors: [String]
}

enum LibraryImporterError: LocalizedError {
    case invalidArchive
    case missingManifest
    case unsupportedVersion(Int)
    case checksumMismatch(String)

    var errorDescription: String? {
        switch self {
        case .invalidArchive: return "The file is not a valid Avatar library."
        case .missingManifest: return "The library file is missing its manifest."
        case .unsupportedVersion(let v):
            return "This library requires a newer version of Avatar (format version \(v))."
        case .checksumMismatch(let path):
            return "Data integrity check failed for \(path)."
        }
    }
}

// MARK: - Importer

@MainActor
final class LibraryImporter {

    /// Reads the manifest and detects conflicts without importing anything.
    static func preview(
        url: URL,
        context: ModelContext
    ) throws -> ImportPreview {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw LibraryImporterError.invalidArchive
        }

        // Read manifest
        let manifest = try readManifest(from: archive)

        // Collect portrait IDs from archive
        let portraitIDs = collectUUIDs(from: archive, prefix: "portraits/")
        let backgroundIDs = collectUUIDs(from: archive, prefix: "backgrounds/")
        let presetIDs = collectPresetUUIDs(from: archive)

        // Check for existing items
        let existingPortraits = try context.fetch(FetchDescriptor<Portrait>())
        let existingPortraitIDs = Set(existingPortraits.map(\.id))

        let existingBackgrounds = try context.fetch(FetchDescriptor<BackgroundPreset>())
        let existingBackgroundIDs = Set(existingBackgrounds.map(\.id))

        return ImportPreview(
            manifest: manifest,
            portraitCount: portraitIDs.count,
            backgroundCount: backgroundIDs.count,
            presetCount: presetIDs.count,
            conflictingPortraitIDs: portraitIDs.intersection(existingPortraitIDs),
            conflictingBackgroundIDs: backgroundIDs.intersection(existingBackgroundIDs)
        )
    }

    /// Imports the library archive into SwiftData.
    static func importLibrary(
        url: URL,
        strategy: ImportConflictStrategy,
        context: ModelContext,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> ImportResult {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw LibraryImporterError.invalidArchive
        }

        let manifest = try readManifest(from: archive)
        let totalItems = manifest.portraitCount + manifest.backgroundCount + manifest.presetCount
        var completedItems = 0
        var importedPortraits = 0
        var importedBackgrounds = 0
        var importedPresets = 0
        var skipped = 0
        var errors: [String] = []

        // UUID remapping for "copy" strategy
        var uuidRemap: [UUID: UUID] = [:]

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // 1. Import backgrounds first (portraits reference them)
        let bgDirs = collectUUIDs(from: archive, prefix: "backgrounds/")
        for bgID in bgDirs {
            let dir = "backgrounds/\(bgID.uuidString)"
            guard let metaData = readEntryData(archive: archive, path: "\(dir)/metadata.json") else {
                errors.append("Missing metadata for background \(bgID)")
                continue
            }

            let dto: BackgroundPresetDTO
            do {
                dto = try decoder.decode(BackgroundPresetDTO.self, from: metaData)
            } catch {
                errors.append("Invalid metadata for background \(bgID): \(error.localizedDescription)")
                continue
            }

            // Check conflict
            let existing = try? context.fetch(
                FetchDescriptor<BackgroundPreset>(predicate: #Predicate { $0.id == bgID })
            ).first

            if existing != nil {
                switch strategy {
                case .skip:
                    skipped += 1
                    completedItems += 1
                    await MainActor.run { progress(Double(completedItems) / Double(totalItems)) }
                    continue
                case .replace:
                    if let existing { context.delete(existing) }
                case .copy:
                    let newID = UUID()
                    uuidRemap[bgID] = newID
                }
            }

            // Read image data if present
            var imageData: Data? = nil
            if dto.hasImage {
                let imgPath = "\(dir)/image.dat"
                imageData = readEntryData(archive: archive, path: imgPath)
                if let imgData = imageData, let expectedHash = manifest.checksums[imgPath] {
                    let actual = sha256(imgData)
                    if actual != expectedHash {
                        errors.append("Checksum mismatch for \(imgPath)")
                        imageData = nil
                    }
                }
            }

            let finalID = uuidRemap[bgID] ?? dto.id
            let bg = BackgroundPreset(
                id: finalID,
                name: dto.name,
                kind: BackgroundKind(rawValue: dto.kind) ?? .color,
                imageData: imageData,
                color: (dto.colorR, dto.colorG, dto.colorB, dto.colorA),
                isDefault: false // Never import as default — keep local default
            )
            context.insert(bg)
            importedBackgrounds += 1

            completedItems += 1
            progress(Double(completedItems) / Double(totalItems))
        }

        // 2. Import portraits
        let portraitDirs = collectUUIDs(from: archive, prefix: "portraits/")
        for pID in portraitDirs {
            try Task.checkCancellation()

            let dir = "portraits/\(pID.uuidString)"
            guard let metaData = readEntryData(archive: archive, path: "\(dir)/metadata.json") else {
                errors.append("Missing metadata for portrait \(pID)")
                continue
            }

            let dto: PortraitDTO
            do {
                dto = try decoder.decode(PortraitDTO.self, from: metaData)
            } catch {
                errors.append("Invalid metadata for portrait \(pID): \(error.localizedDescription)")
                continue
            }

            // Check conflict
            let existing = try? context.fetch(
                FetchDescriptor<Portrait>(predicate: #Predicate { $0.id == pID })
            ).first

            if existing != nil {
                switch strategy {
                case .skip:
                    skipped += 1
                    completedItems += 1
                    progress(Double(completedItems) / Double(totalItems))
                    continue
                case .replace:
                    if let existing { context.delete(existing) }
                case .copy:
                    uuidRemap[pID] = UUID()
                }
            }

            // Read image data with checksum verification
            let original = readAndVerify(archive: archive, path: "\(dir)/original.dat", checksums: manifest.checksums, errors: &errors)
            let cutout = readAndVerify(archive: archive, path: "\(dir)/cutout.png", checksums: manifest.checksums, errors: &errors)
            let preRetouch = readAndVerify(archive: archive, path: "\(dir)/pre-retouch.png", checksums: manifest.checksums, errors: &errors)

            let finalID = uuidRemap[pID] ?? dto.id
            let portrait = Portrait(id: finalID)
            dto.applyTo(portrait)
            portrait.originalImageData = original
            portrait.cutoutPNG = cutout
            portrait.preRetouchPNG = preRetouch

            // Remap background reference if needed
            if let bgRef = dto.backgroundPresetID {
                portrait.backgroundPresetID = uuidRemap[bgRef] ?? bgRef
            }

            context.insert(portrait)
            importedPortraits += 1

            completedItems += 1
            progress(Double(completedItems) / Double(totalItems))
        }

        // 3. Import custom export presets
        let presetIDs = collectPresetUUIDs(from: archive)
        for presetID in presetIDs {
            let path = "presets/\(presetID.uuidString).json"
            guard let data = readEntryData(archive: archive, path: path) else { continue }

            let dto: ExportPresetDTO
            do {
                dto = try decoder.decode(ExportPresetDTO.self, from: data)
            } catch {
                errors.append("Invalid preset \(presetID): \(error.localizedDescription)")
                continue
            }

            // Skip built-in presets
            if dto.isBuiltIn {
                completedItems += 1
                progress(Double(completedItems) / Double(totalItems))
                continue
            }

            // Check if already exists
            let existing = try? context.fetch(
                FetchDescriptor<ExportPreset>(predicate: #Predicate { $0.id == presetID })
            ).first

            if existing != nil {
                skipped += 1
            } else {
                context.insert(dto.toModel())
                importedPresets += 1
            }

            completedItems += 1
            progress(Double(completedItems) / Double(totalItems))
        }

        // 4. Save
        try context.save()

        return ImportResult(
            portraitsImported: importedPortraits,
            backgroundsImported: importedBackgrounds,
            presetsImported: importedPresets,
            skipped: skipped,
            errors: errors
        )
    }

    // MARK: - Helpers

    private static func readManifest(from archive: Archive) throws -> LibraryManifest {
        guard let data = readEntryData(archive: archive, path: "manifest.json") else {
            throw LibraryImporterError.missingManifest
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(LibraryManifest.self, from: data)

        if manifest.formatVersion > LibraryManifest.currentFormatVersion {
            throw LibraryImporterError.unsupportedVersion(manifest.formatVersion)
        }
        return manifest
    }

    private static func readEntryData(archive: Archive, path: String) -> Data? {
        guard let entry = archive[path] else { return nil }
        var result = Data()
        do {
            _ = try archive.extract(entry) { chunk in
                result.append(chunk)
            }
        } catch {
            return nil
        }
        return result
    }

    private static func readAndVerify(
        archive: Archive,
        path: String,
        checksums: [String: String],
        errors: inout [String]
    ) -> Data? {
        guard let data = readEntryData(archive: archive, path: path) else { return nil }
        if let expected = checksums[path] {
            let actual = sha256(data)
            if actual != expected {
                errors.append("Checksum mismatch: \(path)")
                return nil
            }
        }
        return data
    }

    private static func sha256(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Extracts UUIDs from directory-based entries like "portraits/{uuid}/metadata.json"
    private static func collectUUIDs(from archive: Archive, prefix: String) -> Set<UUID> {
        var ids = Set<UUID>()
        for entry in archive {
            let path = entry.path
            guard path.hasPrefix(prefix) else { continue }
            let rest = String(path.dropFirst(prefix.count))
            guard let slashIdx = rest.firstIndex(of: "/") else { continue }
            let uuidStr = String(rest[rest.startIndex..<slashIdx])
            if let uuid = UUID(uuidString: uuidStr) {
                ids.insert(uuid)
            }
        }
        return ids
    }

    /// Extracts UUIDs from preset entries like "presets/{uuid}.json"
    private static func collectPresetUUIDs(from archive: Archive) -> Set<UUID> {
        var ids = Set<UUID>()
        for entry in archive {
            let path = entry.path
            guard path.hasPrefix("presets/"), path.hasSuffix(".json") else { continue }
            let name = String(path.dropFirst("presets/".count).dropLast(".json".count))
            if let uuid = UUID(uuidString: name) {
                ids.insert(uuid)
            }
        }
        return ids
    }
}
