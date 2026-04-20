import SwiftUI
import SwiftData

struct WorkspaceSettingsSheet: View {
    @Bindable var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @Environment(SyncEngine.self) private var syncEngine
    @Environment(GoogleAuthService.self) private var auth
    @Environment(\.modelContext) private var context
    @Query(sort: \Portrait.updatedAt, order: .reverse) private var portraits: [Portrait]
    @Query(sort: \BackgroundPreset.createdAt) private var backgrounds: [BackgroundPreset]

    @State private var shareEmail = ""
    @State private var isSharing = false
    @State private var shareError: String?
    @State private var shareSuccess = false

    @State private var showFolderPicker = false
    @State private var isMoving = false
    @State private var moveError: String?
    @State private var moveSuccess = false

    @State private var members: [DrivePermission] = []
    @State private var isLoadingMembers = false
    @State private var membersError: String?
    @State private var revokingID: String?

    private var isEmailValid: Bool {
        let trimmed = shareEmail.trimmingCharacters(in: .whitespaces)
        let pattern = #"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#
        return trimmed.range(of: pattern, options: .regularExpression) != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(Loc.workspaceSettings).font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            Form {
                // Name
                Section(Loc.name) {
                    TextField(Loc.name, text: $workspace.name)
                }

                // Info
                Section("Info") {
                    LabeledContent(Loc.owner) {
                        Text(workspace.ownerEmail)
                    }
                    LabeledContent(Loc.driveFolder) {
                        HStack(spacing: 6) {
                            Image(systemName: "folder.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Avatar Workspace - \(workspace.name)")
                                .font(.callout)
                            Spacer()

                            if isMoving {
                                ProgressView().controlSize(.mini)
                            } else {
                                Button(Loc.changeLocation) {
                                    moveError = nil
                                    moveSuccess = false
                                    showFolderPicker = true
                                }
                                .font(.caption)
                                .buttonStyle(.plain)
                                .foregroundStyle(Color.accentColor)
                            }

                            Button {
                                let url = URL(string: "https://drive.google.com/drive/folders/\(workspace.driveFolderID)")!
                                NSWorkspace.shared.open(url)
                            } label: {
                                Image(systemName: "arrow.up.right.square")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .help(Loc.openInDrive)
                        }
                    }
                    if let moveError {
                        Text(moveError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    if moveSuccess {
                        Label(Loc.changeLocation, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    if let lastSync = workspace.lastSyncedAt {
                        LabeledContent(Loc.lastSynced) {
                            Text(lastSync, style: .relative)
                        }
                    }
                }

                // Share
                Section(Loc.shareWorkspace) {
                    HStack {
                        TextField("", text: $shareEmail, prompt: Text("email@example.com"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                        Button(Loc.share) {
                            shareWithUser()
                        }
                        .disabled(!isEmailValid || isSharing)
                    }
                    if let shareError {
                        Text(shareError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    if shareSuccess {
                        Label(Loc.shareSuccess, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }

                // Members
                Section(Loc.members) {
                    if isLoadingMembers && members.isEmpty {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text(Loc.loadingMembers)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(members) { permission in
                        memberRow(permission)
                    }
                    if let membersError {
                        Text(membersError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                // Add portraits
                Section(Loc.addToWorkspace) {
                    Text(Loc.addToWorkspaceDesc)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button(Loc.addAllPortraits) {
                        for portrait in portraits {
                            syncEngine.addPortraitToWorkspace(portrait, workspace: workspace, context: context)
                        }
                    }
                    .disabled(portraits.isEmpty)

                    Button(Loc.addAllBackgrounds) {
                        for bg in backgrounds {
                            syncEngine.addBackgroundToWorkspace(bg, workspace: workspace, context: context)
                        }
                    }
                    .disabled(backgrounds.isEmpty)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button(Loc.close) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 420, height: 520)
        .sheet(isPresented: $showFolderPicker) {
            DriveFolderPicker(authService: auth) { folder in
                moveFolder(to: folder)
            }
        }
        .task { await loadMembers() }
    }

    @ViewBuilder
    private func memberRow(_ permission: DrivePermission) -> some View {
        HStack(spacing: 8) {
            if let photo = permission.photoLink.flatMap(URL.init(string:)) {
                AsyncImage(url: photo) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "person.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .frame(width: 24, height: 24)
                .clipShape(Circle())
            } else {
                Image(systemName: "person.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(permission.displayName ?? permission.emailAddress ?? permission.id)
                    .font(.callout)
                Text(permission.emailAddress ?? permission.role)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if permission.isOwner {
                Text(Loc.owner)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if revokingID == permission.id {
                ProgressView().controlSize(.mini)
            } else {
                Button(role: .destructive) {
                    revoke(permission)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(Loc.revoke)
            }
        }
    }

    private func loadMembers() async {
        isLoadingMembers = true
        defer { isLoadingMembers = false }
        do {
            let driveService = DriveService(authService: auth)
            let perms = try await driveService.listPermissions(fileID: workspace.driveFolderID)
            members = perms.sorted { a, b in
                if a.isOwner != b.isOwner { return a.isOwner }
                return (a.displayName ?? a.emailAddress ?? "") < (b.displayName ?? b.emailAddress ?? "")
            }
            membersError = nil
        } catch {
            membersError = error.localizedDescription
        }
    }

    private func revoke(_ permission: DrivePermission) {
        revokingID = permission.id
        Task {
            defer { revokingID = nil }
            do {
                let driveService = DriveService(authService: auth)
                try await driveService.removePermission(
                    fileID: workspace.driveFolderID,
                    permissionID: permission.id
                )
                await loadMembers()
            } catch {
                membersError = error.localizedDescription
            }
        }
    }

    private func moveFolder(to newParent: DriveFolder?) {
        isMoving = true
        moveError = nil
        moveSuccess = false
        Task {
            do {
                let driveService = DriveService(authService: auth)
                try await driveService.moveFile(
                    fileID: workspace.driveFolderID,
                    to: newParent?.id
                )
                moveSuccess = true
            } catch {
                moveError = error.localizedDescription
            }
            isMoving = false
        }
    }

    private func shareWithUser() {
        let email = shareEmail.trimmingCharacters(in: .whitespaces)
        guard !email.isEmpty else { return }
        isSharing = true
        shareError = nil
        shareSuccess = false

        let inviterName = auth.userName ?? auth.userEmail ?? "A colleague"
        let deepLink = AvatarInvite.joinURL(
            folderID: workspace.driveFolderID,
            name: workspace.name,
            invitedEmail: email
        ).absoluteString
        let message = Loc.inviteEmailBody(
            inviterName: inviterName,
            workspaceName: workspace.name,
            downloadURL: AvatarInvite.downloadURL,
            deepLink: deepLink
        )

        Task {
            do {
                let driveService = DriveService(authService: auth)
                try await driveService.shareWithUser(
                    fileID: workspace.driveFolderID,
                    email: email,
                    emailMessage: message
                )
                shareSuccess = true
                shareEmail = ""
                await loadMembers()
            } catch DriveError.httpError(400) {
                // Drive returns 400 when the email is already a collaborator.
                shareError = Loc.alreadyInvited
            } catch {
                shareError = error.localizedDescription
            }
            isSharing = false
        }
    }
}
