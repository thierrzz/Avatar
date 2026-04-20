import Foundation
import SwiftData

@Model
final class Workspace {
    @Attribute(.unique) var id: UUID
    var name: String
    var driveFolderID: String
    var ownerEmail: String
    var createdAt: Date

    /// Drive API change token for incremental polling.
    var lastChangeToken: String?
    /// Last time we successfully synced with Drive.
    var lastSyncedAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        driveFolderID: String,
        ownerEmail: String
    ) {
        self.id = id
        self.name = name
        self.driveFolderID = driveFolderID
        self.ownerEmail = ownerEmail
        self.createdAt = Date()
    }
}
