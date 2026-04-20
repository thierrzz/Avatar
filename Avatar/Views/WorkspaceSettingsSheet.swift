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
                        .disabled(shareEmail.isEmpty || isSharing)
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
        .frame(width: 420, height: 480)
        .sheet(isPresented: $showFolderPicker) {
            DriveFolderPicker(authService: auth) { folder in
                moveFolder(to: folder)
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
            name: workspace.name
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
            } catch {
                shareError = error.localizedDescription
            }
            isSharing = false
        }
    }
}
