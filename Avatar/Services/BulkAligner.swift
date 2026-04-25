import Foundation
import SwiftData

/// Logs and swallows save errors.
@discardableResult
private func save(_ context: ModelContext) -> Bool {
    do {
        try context.save()
        return true
    } catch {
        print("[Save] failed: \(error)")
        return false
    }
}

@MainActor
enum BulkAligner {
    struct Snapshot {
        let id: UUID
        let scale: Double
        let offsetX: Double
        let offsetY: Double
        let updatedAt: Date
    }

    struct Result {
        let aligned: Int
        let skipped: Int
    }

    /// Aligns every portrait whose face was detected to the canonical position
    /// (same face size + same eye level). Portraits without a detected face or
    /// without a decodable cutout are skipped.
    /// Registers a single undo step so the entire batch can be reverted with ⌘Z.
    static func alignAll(
        portraits: [Portrait],
        appState: AppState,
        context: ModelContext,
        undoManager: UndoManager?
    ) -> Result {
        var before: [Snapshot] = []
        var after: [Snapshot] = []
        var skipped = 0
        let now = Date()

        for p in portraits {
            guard p.faceRect != .zero, let cutout = appState.cutout(for: p) else {
                skipped += 1
                continue
            }
            before.append(.init(id: p.id, scale: p.scale, offsetX: p.offsetX,
                                offsetY: p.offsetY, updatedAt: p.updatedAt))
            let size = CGSize(width: cutout.width, height: cutout.height)
            let t = AutoAligner.computeTransform(
                faceRect: p.faceRect,
                eyeCenter: p.eyeCenter,
                interEyeDistance: CGFloat(p.interEyeDistance),
                cutoutSize: size,
                bodyBottomY: CGFloat(p.bodyBottomY))
            p.scale = Double(t.scale)
            p.offsetX = Double(t.offset.width)
            p.offsetY = Double(t.offset.height)
            p.updatedAt = now
            after.append(.init(id: p.id, scale: p.scale, offsetX: p.offsetX,
                               offsetY: p.offsetY, updatedAt: p.updatedAt))
        }

        save(context)
        registerUndo(before: before, after: after, context: context, undoManager: undoManager)
        return Result(aligned: before.count, skipped: skipped)
    }

    // MARK: - Undo / Redo

    private static func registerUndo(
        before: [Snapshot], after: [Snapshot],
        context: ModelContext, undoManager: UndoManager?
    ) {
        guard let um = undoManager, !before.isEmpty else { return }
        um.registerUndo(withTarget: context) { ctx in
            apply(before, in: ctx)
            try? ctx.save()
            // Registering inside the undo handler makes this the redo action.
            registerUndo(before: after, after: before, context: ctx, undoManager: um)
        }
        um.setActionName(Loc.alignAllPortraits)
    }

    private static func apply(_ snaps: [Snapshot], in context: ModelContext) {
        let ids = Set(snaps.map(\.id))
        let descriptor = FetchDescriptor<Portrait>(predicate: #Predicate { ids.contains($0.id) })
        guard let fetched = try? context.fetch(descriptor) else { return }
        let byID = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })
        for s in snaps {
            guard let p = byID[s.id] else { continue }
            p.scale = s.scale
            p.offsetX = s.offsetX
            p.offsetY = s.offsetY
            p.updatedAt = s.updatedAt
        }
    }
}
