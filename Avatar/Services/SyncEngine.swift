import Foundation
import SwiftData
import ZIPFoundation

/// Manages automatic synchronization between the local SwiftData store and
/// Google Drive workspaces. Runs a polling loop for remote changes and
/// detects local changes via timestamp comparison.
@MainActor
@Observable
final class SyncEngine {

    private let authService: GoogleAuthService
    private let driveService: DriveService
    private var pollingTask: Task<Void, Never>?
    private(set) var isSyncing = false

    /// Per-workspace sync status for the UI.
    var workspaceSyncErrors: [UUID: String] = [:]

    /// Polling interval in seconds.
    private let pollInterval: TimeInterval = 30

    init(authService: GoogleAuthService) {
        self.authService = authService
        self.driveService = DriveService(authService: authService)
    }

    // MARK: - Lifecycle

    /// Starts the sync polling loop. Call after sign-in.
    func startPolling(context: ModelContext) {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.authService.isSignedIn else {
                    try? await Task.sleep(for: .seconds(5))
                    continue
                }
                await self.syncAll(context: context)
                try? await Task.sleep(for: .seconds(self.pollInterval))
            }
        }
    }

    /// Stops the polling loop. Call on sign-out.
    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    // MARK: - Full sync cycle

    /// Runs a complete sync for all workspaces.
    func syncAll(context: ModelContext) async {
        guard authService.isSignedIn, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        do {
            try await discoverSharedWorkspaces(context: context)
        } catch {
            print("[Sync] discover shared workspaces error: \(error)")
        }

        do {
            let workspaces = try context.fetch(FetchDescriptor<Workspace>())
            for workspace in workspaces {
                do {
                    try await syncWorkspace(workspace, context: context)
                    workspaceSyncErrors.removeValue(forKey: workspace.id)
                } catch {
                    workspaceSyncErrors[workspace.id] = error.localizedDescription
                    print("[Sync] workspace \(workspace.name) error: \(error)")
                }
            }
        } catch {
            print("[Sync] fetch workspaces error: \(error)")
        }
    }

    // MARK: - Workspace sync

    private func syncWorkspace(_ workspace: Workspace, context: ModelContext) async throws {
        // 1. Upload pending items
        try await uploadPendingItems(workspace: workspace, context: context)

        // 2. Check for remote changes
        try await checkRemoteChanges(workspace: workspace, context: context)

        // 3. Download pending items
        try await downloadPendingItems(workspace: workspace, context: context)

        workspace.lastSyncedAt = Date()
        try context.save()
    }

    // MARK: - Upload

    private func uploadPendingItems(workspace: Workspace, context: ModelContext) async throws {
        let wsID = workspace.id
        let pendingStates = try context.fetch(
            FetchDescriptor<SyncState>(predicate: #Predicate {
                $0.workspaceID == wsID && $0.statusRaw == "pendingUpload"
            })
        )

        for state in pendingStates {
            try Task.checkCancellation()

            if state.kind == .portrait {
                try await uploadPortrait(state: state, workspace: workspace, context: context)
            } else {
                try await uploadBackground(state: state, workspace: workspace, context: context)
            }
        }
    }

    private func uploadPortrait(state: SyncState, workspace: Workspace, context: ModelContext) async throws {
        let itemID = state.itemID
        guard let portrait = try context.fetch(
            FetchDescriptor<Portrait>(predicate: #Predicate { $0.id == itemID })
        ).first else {
            // Portrait was deleted — delete from Drive too
            if let fileID = state.driveFileID {
                try await driveService.deleteFile(fileID: fileID)
            }
            context.delete(state)
            return
        }

        // Package as mini-ZIP (reuse archiver logic)
        let data = try packagePortrait(portrait)

        let fileName = "\(portrait.id.uuidString).avatarportrait"

        if let existingFileID = state.driveFileID {
            // Update existing file
            let result = try await driveService.updateFile(fileID: existingFileID, data: data)
            state.remoteMD5 = result.md5Checksum
            state.remoteUpdatedAt = result.modifiedTime
        } else {
            // Ensure portraits subfolder exists
            let portraitsFolderID = try await ensureSubfolder(
                name: "portraits",
                parentID: workspace.driveFolderID
            )
            let result = try await driveService.uploadFile(
                name: fileName,
                data: data,
                parentFolderID: portraitsFolderID
            )
            state.driveFileID = result.id
            state.remoteMD5 = result.md5Checksum
            state.remoteUpdatedAt = result.modifiedTime
        }

        state.localUpdatedAt = portrait.updatedAt
        state.status = .synced
        try context.save()
        print("[Sync] uploaded portrait \(portrait.name) (\(portrait.id))")
    }

    private func uploadBackground(state: SyncState, workspace: Workspace, context: ModelContext) async throws {
        let itemID = state.itemID
        guard let bg = try context.fetch(
            FetchDescriptor<BackgroundPreset>(predicate: #Predicate { $0.id == itemID })
        ).first else {
            if let fileID = state.driveFileID {
                try await driveService.deleteFile(fileID: fileID)
            }
            context.delete(state)
            return
        }

        let data = try packageBackground(bg)
        let fileName = "\(bg.id.uuidString).avatarbg"

        if let existingFileID = state.driveFileID {
            let result = try await driveService.updateFile(fileID: existingFileID, data: data)
            state.remoteMD5 = result.md5Checksum
            state.remoteUpdatedAt = result.modifiedTime
        } else {
            let bgFolderID = try await ensureSubfolder(
                name: "backgrounds",
                parentID: workspace.driveFolderID
            )
            let result = try await driveService.uploadFile(
                name: fileName,
                data: data,
                parentFolderID: bgFolderID
            )
            state.driveFileID = result.id
            state.remoteMD5 = result.md5Checksum
            state.remoteUpdatedAt = result.modifiedTime
        }

        state.localUpdatedAt = bg.createdAt
        state.status = .synced
        try context.save()
        print("[Sync] uploaded background \(bg.name) (\(bg.id))")
    }

    // MARK: - Remote change detection

    private func checkRemoteChanges(workspace: Workspace, context: ModelContext) async throws {
        guard let token = workspace.lastChangeToken else {
            // First sync — get initial token
            let startToken = try await driveService.getStartPageToken()
            workspace.lastChangeToken = startToken
            return
        }

        let (changes, nextToken) = try await driveService.listChanges(pageToken: token)
        if let nextToken {
            workspace.lastChangeToken = nextToken
        }

        for change in changes {
            guard let fileId = change.fileId else { continue }

            // Find the sync state that references this Drive file
            let syncStates = try context.fetch(FetchDescriptor<SyncState>())
            guard let state = syncStates.first(where: { $0.driveFileID == fileId }) else {
                // Unknown file — might be a new item from another device
                // Check if it's in our workspace folders
                if let file = change.file, !file.name.isEmpty {
                    if file.name.hasSuffix(".avatarportrait") || file.name.hasSuffix(".avatarbg") {
                        // Mark for download by creating a new sync state
                        let uuidStr = file.name.replacingOccurrences(of: ".avatarportrait", with: "")
                            .replacingOccurrences(of: ".avatarbg", with: "")
                        if let uuid = UUID(uuidString: uuidStr) {
                            let kind: SyncItemKind = file.name.hasSuffix(".avatarportrait") ? .portrait : .background
                            let newState = SyncState(itemID: uuid, itemKind: kind, workspaceID: workspace.id)
                            newState.driveFileID = fileId
                            newState.remoteMD5 = file.md5Checksum
                            newState.remoteUpdatedAt = file.modifiedTime
                            newState.status = .pendingDownload
                            context.insert(newState)
                        }
                    }
                }
                continue
            }

            // Check if remote changed
            if let remoteMD5 = change.file?.md5Checksum, remoteMD5 != state.remoteMD5 {
                if state.status == .pendingUpload {
                    // Both sides changed — conflict
                    state.status = .conflict
                } else {
                    state.status = .pendingDownload
                    state.remoteMD5 = remoteMD5
                    state.remoteUpdatedAt = change.file?.modifiedTime
                }
            }
        }

        try context.save()
    }

    // MARK: - Download

    private func downloadPendingItems(workspace: Workspace, context: ModelContext) async throws {
        let wsID = workspace.id
        let pendingStates = try context.fetch(
            FetchDescriptor<SyncState>(predicate: #Predicate {
                $0.workspaceID == wsID && $0.statusRaw == "pendingDownload"
            })
        )

        for state in pendingStates {
            try Task.checkCancellation()
            guard let fileID = state.driveFileID else { continue }

            do {
                let data = try await driveService.downloadFile(fileID: fileID)

                if state.kind == .portrait {
                    try importPortraitData(data, state: state, context: context)
                } else {
                    try importBackgroundData(data, state: state, context: context)
                }

                state.status = .synced
                try context.save()
            } catch {
                print("[Sync] download failed for \(state.itemID): \(error)")
            }
        }
    }

    // MARK: - Conflict resolution

    /// Resolves a conflict by keeping the local version and re-uploading.
    func resolveConflictKeepLocal(state: SyncState, context: ModelContext) {
        state.status = .pendingUpload
        try? context.save()
    }

    /// Resolves a conflict by downloading the remote version.
    func resolveConflictKeepRemote(state: SyncState, context: ModelContext) {
        state.status = .pendingDownload
        try? context.save()
    }

    // MARK: - Add/remove items to workspace

    /// Adds a portrait to a workspace for syncing.
    func addPortraitToWorkspace(_ portrait: Portrait, workspace: Workspace, context: ModelContext) {
        let state = SyncState(
            itemID: portrait.id,
            itemKind: .portrait,
            workspaceID: workspace.id,
            localUpdatedAt: portrait.updatedAt
        )
        context.insert(state)
        try? context.save()
    }

    /// Adds a background to a workspace for syncing.
    func addBackgroundToWorkspace(_ bg: BackgroundPreset, workspace: Workspace, context: ModelContext) {
        let state = SyncState(
            itemID: bg.id,
            itemKind: .background,
            workspaceID: workspace.id,
            localUpdatedAt: bg.createdAt
        )
        context.insert(state)
        try? context.save()
    }

    /// Marks a portrait as changed so it gets re-uploaded.
    func markPortraitChanged(_ portrait: Portrait, context: ModelContext) {
        let portraitID = portrait.id
        let states = try? context.fetch(
            FetchDescriptor<SyncState>(predicate: #Predicate {
                $0.itemID == portraitID && $0.itemKind == "portrait"
            })
        )
        for state in states ?? [] {
            if state.status == .synced {
                state.status = .pendingUpload
                state.localUpdatedAt = portrait.updatedAt
            }
        }
        try? context.save()
    }

    // MARK: - Workspace CRUD

    /// Creates a new workspace (Drive folder + local model).
    func createWorkspace(name: String, parentFolderID: String? = nil, context: ModelContext) async throws -> Workspace {
        let folderName = "Avatar Workspace - \(name)"
        let folderID = try await driveService.createFolder(name: folderName, parentID: parentFolderID)

        // Create subfolders
        _ = try await driveService.createFolder(name: "portraits", parentID: folderID)
        _ = try await driveService.createFolder(name: "backgrounds", parentID: folderID)

        // Write workspace.json metadata
        let meta: [String: Any] = [
            "formatVersion": 1,
            "name": name,
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "createdBy": authService.userEmail ?? "unknown"
        ]
        let metaData = try JSONSerialization.data(withJSONObject: meta, options: .prettyPrinted)
        _ = try await driveService.uploadFile(
            name: "workspace.json",
            data: metaData,
            mimeType: "application/json",
            parentFolderID: folderID
        )

        // Get initial change token
        let changeToken = try await driveService.getStartPageToken()

        let workspace = Workspace(
            name: name,
            driveFolderID: folderID,
            ownerEmail: authService.userEmail ?? "unknown"
        )
        workspace.lastChangeToken = changeToken
        context.insert(workspace)
        try context.save()

        print("[Sync] created workspace '\(name)' folderID=\(folderID)")
        return workspace
    }

    /// Discovers existing workspaces on Drive (e.g., after reinstall).
    func discoverWorkspaces(context: ModelContext) async throws -> [DriveFile] {
        let folders = try await driveService.findWorkspaceFolders()
        return folders
    }

    /// Adds a Drive workspace folder to the local library. Used for both
    /// `avatar://join` deep links and automatic discovery of folders shared
    /// with the signed-in user. Reads `workspace.json` for metadata when
    /// available; falls back to the folder name on missing/malformed JSON.
    @discardableResult
    func joinWorkspace(
        folderID: String,
        folderName: String,
        context: ModelContext
    ) async throws -> Workspace {
        if let existing = try context.fetch(
            FetchDescriptor<Workspace>(predicate: #Predicate { $0.driveFolderID == folderID })
        ).first {
            return existing
        }

        let meta = try? await readWorkspaceMetadata(folderID: folderID)
        let displayName = meta?.name ?? folderName
            .replacingOccurrences(of: "Avatar Workspace - ", with: "")
        let ownerEmail = meta?.createdBy ?? "unknown"

        let changeToken = try await driveService.getStartPageToken()
        let workspace = Workspace(
            name: displayName,
            driveFolderID: folderID,
            ownerEmail: ownerEmail
        )
        workspace.lastChangeToken = changeToken
        context.insert(workspace)
        try context.save()
        print("[Sync] joined workspace '\(displayName)' folderID=\(folderID)")
        return workspace
    }

    /// Enumerates workspace folders on Drive (including ones shared with
    /// the signed-in user) and joins any that aren't already local.
    /// Silently skips folders that fail to join — a bad entry must not
    /// block syncing the rest.
    func discoverSharedWorkspaces(context: ModelContext) async throws {
        let remote = try await driveService.findWorkspaceFolders()
        guard !remote.isEmpty else { return }

        let localIDs = Set(
            (try? context.fetch(FetchDescriptor<Workspace>()))?.map(\.driveFolderID) ?? []
        )

        for folder in remote where !localIDs.contains(folder.id) {
            do {
                _ = try await joinWorkspace(
                    folderID: folder.id,
                    folderName: folder.name,
                    context: context
                )
            } catch {
                print("[Sync] auto-join failed for \(folder.name): \(error)")
            }
        }
    }

    private struct WorkspaceMetadata: Decodable {
        let formatVersion: Int?
        let name: String?
        let createdAt: String?
        let createdBy: String?
    }

    private func readWorkspaceMetadata(folderID: String) async throws -> WorkspaceMetadata? {
        let files = try await driveService.listFiles(inFolder: folderID, mimeType: "application/json")
        guard let metaFile = files.first(where: { $0.name == "workspace.json" }) else {
            return nil
        }
        let data = try await driveService.downloadFile(fileID: metaFile.id)
        return try JSONDecoder().decode(WorkspaceMetadata.self, from: data)
    }

    // MARK: - Packaging helpers

    private func packagePortrait(_ portrait: Portrait) throws -> Data {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("avatarportrait")

        let archive = try Archive(url: tempURL, accessMode: .create)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let dto = PortraitDTO(from: portrait)
        let metaData = try encoder.encode(dto)

        try addArchiveEntry(archive: archive, path: "metadata.json", data: metaData, compress: true)
        if let original = portrait.originalImageData {
            try addArchiveEntry(archive: archive, path: "original.dat", data: original, compress: false)
        }
        if let cutout = portrait.cutoutPNG {
            try addArchiveEntry(archive: archive, path: "cutout.png", data: cutout, compress: false)
        }
        if let preRetouch = portrait.preRetouchPNG {
            try addArchiveEntry(archive: archive, path: "pre-retouch.png", data: preRetouch, compress: false)
        }

        let result = try Data(contentsOf: tempURL)
        try? FileManager.default.removeItem(at: tempURL)
        return result
    }

    private func packageBackground(_ bg: BackgroundPreset) throws -> Data {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("avatarbg")

        let archive = try Archive(url: tempURL, accessMode: .create)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let dto = BackgroundPresetDTO(from: bg)
        let metaData = try encoder.encode(dto)

        try addArchiveEntry(archive: archive, path: "metadata.json", data: metaData, compress: true)
        if let imgData = bg.imageData {
            try addArchiveEntry(archive: archive, path: "image.dat", data: imgData, compress: false)
        }

        let result = try Data(contentsOf: tempURL)
        try? FileManager.default.removeItem(at: tempURL)
        return result
    }

    private func addArchiveEntry(archive: Archive, path: String, data: Data, compress: Bool) throws {
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

    private func importPortraitData(_ data: Data, state: SyncState, context: ModelContext) throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let archive = try Archive(url: tempURL, accessMode: .read)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let metaEntry = archive["metadata.json"] else { return }
        var metaData = Data()
        _ = try archive.extract(metaEntry) { metaData.append($0) }
        let dto = try decoder.decode(PortraitDTO.self, from: metaData)

        let itemID = state.itemID
        let existing = try context.fetch(
            FetchDescriptor<Portrait>(predicate: #Predicate { $0.id == itemID })
        ).first

        let portrait = existing ?? Portrait(id: state.itemID)
        dto.applyTo(portrait)

        // Extract image data
        if let entry = archive["original.dat"] {
            var d = Data(); _ = try archive.extract(entry) { d.append($0) }
            portrait.originalImageData = d
        }
        if let entry = archive["cutout.png"] {
            var d = Data(); _ = try archive.extract(entry) { d.append($0) }
            portrait.cutoutPNG = d
        }
        if let entry = archive["pre-retouch.png"] {
            var d = Data(); _ = try archive.extract(entry) { d.append($0) }
            portrait.preRetouchPNG = d
        }

        if existing == nil {
            context.insert(portrait)
        }

        print("[Sync] imported portrait \(portrait.name) (\(portrait.id))")
    }

    private func importBackgroundData(_ data: Data, state: SyncState, context: ModelContext) throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let archive = try Archive(url: tempURL, accessMode: .read)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let metaEntry = archive["metadata.json"] else { return }
        var metaData = Data()
        _ = try archive.extract(metaEntry) { metaData.append($0) }
        let dto = try decoder.decode(BackgroundPresetDTO.self, from: metaData)

        var imageData: Data? = nil
        if let entry = archive["image.dat"] {
            var d = Data(); _ = try archive.extract(entry) { d.append($0) }
            imageData = d
        }

        let itemID = state.itemID
        let existing = try context.fetch(
            FetchDescriptor<BackgroundPreset>(predicate: #Predicate { $0.id == itemID })
        ).first

        if let existing {
            // Update in place
            existing.imageData = imageData
        } else {
            let bg = dto.toModel(imageData: imageData)
            context.insert(bg)
        }

        print("[Sync] imported background \(dto.name) (\(dto.id))")
    }

    // MARK: - Subfolder cache

    private var subfolderCache: [String: String] = [:]

    private func ensureSubfolder(name: String, parentID: String) async throws -> String {
        let key = "\(parentID)/\(name)"
        if let cached = subfolderCache[key] { return cached }

        let files = try await driveService.listFiles(
            inFolder: parentID,
            mimeType: "application/vnd.google-apps.folder"
        )

        if let existing = files.first(where: { $0.name == name }) {
            subfolderCache[key] = existing.id
            return existing.id
        }

        let newID = try await driveService.createFolder(name: name, parentID: parentID)
        subfolderCache[key] = newID
        return newID
    }
}
