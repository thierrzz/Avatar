import SwiftUI
import SwiftData

/// Notion-style workspace switcher at the top of the sidebar.
/// Shows the currently selected workspace (or "My Library") and opens
/// a popover for switching, creating, and managing workspaces.
struct WorkspaceSwitcher: View {
    @Environment(AppState.self) private var appState
    @Environment(GoogleAuthService.self) private var auth
    @Environment(SyncEngine.self) private var syncEngine
    @Environment(\.modelContext) private var context
    @Query(sort: \Workspace.createdAt) private var workspaces: [Workspace]

    @State private var showPopover = false
    @State private var showNewWorkspace = false
    @State private var newWorkspaceName = ""
    @State private var selectedParentFolder: DriveFolder? = nil
    @State private var showFolderPicker = false
    @State private var isCreating = false
    @State private var createError: String?
    @State private var showSettings: Workspace?
    @State private var isHovering = false

    /// The currently selected workspace model, if any.
    private var selectedWorkspace: Workspace? {
        guard let id = appState.selectedWorkspaceID else { return nil }
        return workspaces.first(where: { $0.id == id })
    }

    var body: some View {
        VStack(spacing: 0) {
            switcherBar
            // When viewing a workspace, show a settings bar with quick actions
            if let ws = selectedWorkspace {
                workspaceActionBar(ws)
            }
        }
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            popoverContent
        }
        .sheet(item: $showSettings) { workspace in
            WorkspaceSettingsSheet(workspace: workspace)
        }
        .onChange(of: workspaces.map(\.id)) { _, newIDs in
            if let selected = appState.selectedWorkspaceID,
               !newIDs.contains(selected) {
                appState.selectedWorkspaceID = nil
            }
        }
        .onChange(of: auth.isSignedIn) { _, signedIn in
            if !signedIn {
                appState.selectedWorkspaceID = nil
            }
        }
    }

    // MARK: - Switcher Bar

    private var switcherBar: some View {
        Button {
            showPopover.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selectedWorkspace != nil ? "cloud.fill" : "house.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(selectedWorkspace != nil ? .blue : .secondary)

                Text(selectedWorkspace?.name ?? Loc.myLibrary)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                Spacer()

                if let ws = selectedWorkspace {
                    syncStatusIcon(for: ws)
                }

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovering ? Color(.controlBackgroundColor) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .padding(.horizontal, 4)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    // MARK: - Workspace Action Bar (visible when a workspace is selected)

    private func workspaceActionBar(_ workspace: Workspace) -> some View {
        HStack(spacing: 4) {
            // Settings button
            Button {
                showSettings = workspace
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 10))
                    Text(Loc.workspaceSettings)
                        .font(.system(size: 10))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(.controlBackgroundColor))
                )
            }
            .buttonStyle(.plain)

            // Invite button
            Button {
                showSettings = workspace
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 10))
                    Text(Loc.inviteMembers)
                        .font(.system(size: 10))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(.controlBackgroundColor))
                )
            }
            .buttonStyle(.plain)

            Spacer()

            // Sync status
            if let error = syncEngine.workspaceSyncErrors[workspace.id] {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .help(error)
            } else if let lastSync = workspace.lastSyncedAt {
                Text(lastSync, style: .relative)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    // MARK: - Popover Content

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Account section
            accountSection
                .padding(12)

            Divider()

            // Workspace list
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    // My Library (always available)
                    popoverRow(
                        name: Loc.myLibrary,
                        icon: "house.fill",
                        iconColor: .secondary,
                        isSelected: appState.selectedWorkspaceID == nil
                    ) {
                        appState.selectedWorkspaceID = nil
                        appState.selectedPortraitIDs.removeAll()
                        showPopover = false
                    }

                    if !workspaces.isEmpty {
                        Divider()
                            .padding(.vertical, 4)
                    }

                    ForEach(workspaces) { workspace in
                        popoverWorkspaceRow(workspace)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 300)

            Divider()

            // New workspace / create section
            if auth.isSignedIn {
                newWorkspaceSection
                    .padding(8)
            }
        }
        .frame(width: 280)
    }

    // MARK: - Popover Workspace Row (with gear icon)

    private func popoverWorkspaceRow(_ workspace: Workspace) -> some View {
        HStack(spacing: 0) {
            // Main clickable area — selects the workspace
            Button {
                appState.selectedWorkspaceID = workspace.id
                appState.selectedPortraitIDs.removeAll()
                showPopover = false
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "cloud.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.blue)
                        .frame(width: 16)

                    Text(workspace.name)
                        .font(.system(size: 13))
                        .lineLimit(1)

                    Spacer()

                    if let syncView = syncStatusView(for: workspace) {
                        syncView
                    }

                    if appState.selectedWorkspaceID == workspace.id {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Settings gear icon
            Button {
                showPopover = false
                // Small delay so popover dismisses before sheet appears
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    showSettings = workspace
                }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Loc.workspaceSettings)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(appState.selectedWorkspaceID == workspace.id
                      ? Color.accentColor.opacity(0.1) : .clear)
        )
        .contextMenu {
            Button(Loc.workspaceSettings) {
                showSettings = workspace
            }
            Divider()
            Button(Loc.delete, role: .destructive) {
                if appState.selectedWorkspaceID == workspace.id {
                    appState.selectedWorkspaceID = nil
                }
                context.delete(workspace)
                try? context.save()
            }
        }
    }

    // MARK: - Account Section

    @ViewBuilder
    private var accountSection: some View {
        if auth.isSignedIn {
            HStack(spacing: 10) {
                if let avatarURL = auth.userAvatarURL {
                    AsyncImage(url: avatarURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: "person.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 32, height: 32)
                    .clipShape(Circle())
                } else {
                    Image(systemName: "person.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(auth.userName ?? "")
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(auth.userEmail ?? "")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    auth.signOut()
                    appState.selectedWorkspaceID = nil
                    showPopover = false
                } label: {
                    Text(Loc.signOut)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        } else {
            Button {
                auth.signIn()
                showPopover = false
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "person.badge.key")
                    Text(Loc.signInWithGoogle)
                        .font(.system(size: 12))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .disabled(auth.isSigningIn)
        }
    }

    // MARK: - Simple Popover Row (for My Library)

    private func popoverRow(
        name: String,
        icon: String,
        iconColor: Color,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(iconColor)
                    .frame(width: 16)

                Text(name)
                    .font(.system(size: 13))
                    .lineLimit(1)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isSelected ? Color.accentColor.opacity(0.1) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - New Workspace Section

    private var newWorkspaceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showNewWorkspace {
                // Chosen folder (prominent display)
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.blue)

                    Text(selectedParentFolder?.name ?? Loc.myDrive)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)

                    Spacer()

                    Button(Loc.changeFolder) {
                        showFolderPicker = true
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }

                // Name field (pre-filled with folder name)
                TextField(Loc.name, text: $newWorkspaceName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { createWorkspace() }

                // Create + Cancel
                HStack {
                    Button(Loc.createWorkspace) {
                        createWorkspace()
                    }
                    .font(.system(size: 12))
                    .disabled(newWorkspaceName.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)

                    Spacer()

                    Button {
                        resetNewWorkspaceForm()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                if isCreating {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                        Text(Loc.syncing)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = createError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            } else {
                // "+ New Workspace" button — opens folder picker directly
                Button {
                    showFolderPicker = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 11))
                        Text(Loc.newWorkspace)
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $showFolderPicker) {
            DriveFolderPicker(authService: auth) { folder in
                selectedParentFolder = folder
                // Pre-fill workspace name with folder name (or default)
                newWorkspaceName = folder?.name ?? "My Workspace"
                showNewWorkspace = true
            }
        }
    }

    private func resetNewWorkspaceForm() {
        showNewWorkspace = false
        newWorkspaceName = ""
        selectedParentFolder = nil
        createError = nil
    }

    // MARK: - Sync Status

    @ViewBuilder
    private func syncStatusIcon(for workspace: Workspace) -> some View {
        if syncEngine.workspaceSyncErrors[workspace.id] != nil {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
        } else if syncEngine.isSyncing {
            ProgressView()
                .controlSize(.mini)
        }
    }

    private func syncStatusView(for workspace: Workspace) -> AnyView? {
        if let error = syncEngine.workspaceSyncErrors[workspace.id] {
            return AnyView(
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .help(error)
            )
        } else if syncEngine.isSyncing {
            return AnyView(
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            )
        }
        return nil
    }

    // MARK: - Actions

    private func createWorkspace() {
        let name = newWorkspaceName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        isCreating = true
        createError = nil

        Task {
            do {
                let workspace = try await syncEngine.createWorkspace(
                    name: name,
                    parentFolderID: selectedParentFolder?.id,
                    context: context
                )
                appState.selectedWorkspaceID = workspace.id
                appState.selectedPortraitIDs.removeAll()
                newWorkspaceName = ""
                selectedParentFolder = nil
                showNewWorkspace = false
                showPopover = false
            } catch {
                createError = error.localizedDescription
            }
            isCreating = false
        }
    }
}
