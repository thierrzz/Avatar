import Foundation
import SwiftData

enum SyncStatus: String, Codable {
    case synced
    case pendingUpload
    case pendingDownload
    case conflict
}

enum SyncItemKind: String, Codable {
    case portrait
    case background
}

@Model
final class SyncState {
    @Attribute(.unique) var id: UUID

    /// The UUID of the portrait or background this sync state tracks.
    var itemID: UUID
    var itemKind: String   // SyncItemKind raw value

    /// The workspace this item belongs to.
    var workspaceID: UUID

    /// Google Drive file ID of the uploaded .avatarportrait / .avatarbg file.
    var driveFileID: String?

    /// Timestamps for change detection.
    var localUpdatedAt: Date
    var remoteUpdatedAt: Date?

    /// MD5 checksum of the remote file (provided by Google Drive API).
    var remoteMD5: String?

    /// Current sync status.
    var statusRaw: String

    init(
        itemID: UUID,
        itemKind: SyncItemKind,
        workspaceID: UUID,
        localUpdatedAt: Date = Date()
    ) {
        self.id = UUID()
        self.itemID = itemID
        self.itemKind = itemKind.rawValue
        self.workspaceID = workspaceID
        self.localUpdatedAt = localUpdatedAt
        self.statusRaw = SyncStatus.pendingUpload.rawValue
    }

    var status: SyncStatus {
        get { SyncStatus(rawValue: statusRaw) ?? .pendingUpload }
        set { statusRaw = newValue.rawValue }
    }

    var kind: SyncItemKind {
        SyncItemKind(rawValue: itemKind) ?? .portrait
    }
}
