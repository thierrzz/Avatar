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
        try? context.save()
    }

    private static func seedDefaultBackgroundIfNeeded(context: ModelContext) {
        let descriptor = FetchDescriptor<BackgroundPreset>()
        let existing = (try? context.fetch(descriptor)) ?? []
        if !existing.isEmpty { return }

        var data: Data? = nil
        if let url = Bundle.main.url(forResource: "DefaultBackground", withExtension: "png") {
            data = try? Data(contentsOf: url)
        }

        let preset = BackgroundPreset(
            name: Loc.defaultBg,
            kind: data != nil ? .image : .color,
            imageData: data,
            color: (0.94, 0.95, 0.97, 1.0),
            isDefault: true
        )
        context.insert(preset)
        try? context.save()
    }
}
