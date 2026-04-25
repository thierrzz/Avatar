import Foundation
import SwiftData
import AppKit

enum SeedData {
    static func seedIfNeeded(context: ModelContext) {
        seedExportPresetsIfNeeded(context: context)
        seedDefaultBackgroundIfNeeded(context: context)
    }

    private static func seedExportPresetsIfNeeded(context: ModelContext) {
        // Platform guidelines:
        //  - LinkedIn accepts up to 8MB; 800×800 is the recommended profile size
        //    and LinkedIn itself masks to a circle, so we ship a SQUARE.
        //  - Slack requires square, minimum 512×512 (Slack masks corners).
        //  - Email (signatures) are rendered as-is by most clients, square is safe.
        //  - Generiek S/M/L for arbitrary use — default to square, user can
        //    toggle the canvas shape to circle before export if they need it.
        let builtIns: [(String, Int, Int, ExportShape)] = [
            ("LinkedIn",   800,  800, .square),
            ("Slack",      512,  512, .square),
            ("Email",      400,  400, .square),
            ("Generiek L", 1024, 1024, .square),
            ("Generiek M", 512,  512, .square),
            ("Generiek S", 256,  256, .square),
        ]

        // Upsert by name so existing installs pick up corrected values
        // (e.g. LinkedIn was previously circle; should be square). User-renamed
        // or user-deleted built-ins are left alone.
        let descriptor = FetchDescriptor<ExportPreset>(
            predicate: #Predicate { $0.isBuiltIn == true }
        )
        let existing = (try? context.fetch(descriptor)) ?? []
        let byName = Dictionary(uniqueKeysWithValues: existing.map { ($0.name, $0) })

        for (idx, item) in builtIns.enumerated() {
            if let current = byName[item.0] {
                current.width = item.1
                current.height = item.2
                current.shape = item.3
                current.sortOrder = idx
            } else {
                context.insert(ExportPreset(
                    name: item.0, width: item.1, height: item.2,
                    shape: item.3, isBuiltIn: true, sortOrder: idx
                ))
            }
        }
        saveModel(context)
    }

    private static func seedDefaultBackgroundIfNeeded(context: ModelContext) {
        // (resource filename without extension, display name, isDefault)
        let seeds: [(String, String, Bool)] = [
            ("DefaultBackground", Loc.defaultBg, true),
            ("Mesh 01", "Mesh 01", false),
            ("Mesh 02", "Mesh 02", false),
            ("Mesh 03", "Mesh 03", false),
            ("Mesh 04", "Mesh 04", false),
            ("Mesh 05", "Mesh 05", false),
            ("Mesh 06", "Mesh 06", false),
        ]

        let descriptor = FetchDescriptor<BackgroundPreset>()
        let existing = (try? context.fetch(descriptor)) ?? []
        let existingNames = Set(existing.map(\.name))

        var didInsert = false
        for (resource, displayName, isDefault) in seeds {
            if existingNames.contains(displayName) { continue }

            var data: Data? = nil
            if let url = Bundle.main.url(forResource: resource, withExtension: "png") {
                data = try? Data(contentsOf: url)
            }
            guard data != nil else { continue }

            let preset = BackgroundPreset(
                name: displayName,
                kind: .image,
                imageData: data,
                color: (0.94, 0.95, 0.97, 1.0),
                isDefault: isDefault
            )
            context.insert(preset)
            didInsert = true
        }

        if didInsert { saveModel(context) }
    }
}
