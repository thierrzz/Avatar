import Foundation
import SwiftData

/// Logs and swallows save errors to avoid crashing the UI on transient issues.
@discardableResult
func save(_ context: ModelContext) -> Bool {
    do {
        try context.save()
        return true
    } catch {
        print("[Save] failed: \(error)")
        return false
    }
}