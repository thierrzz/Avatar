import SwiftUI
import SwiftData

struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var appState
    @Environment(UpdateManager.self) private var updater
    @Query(sort: \Portrait.updatedAt, order: .reverse) private var allPortraits: [Portrait]
    @Query private var backgrounds: [BackgroundPreset]
    @Query private var syncStates: [SyncState]
    @Query(sort: \Workspace.name) private var allWorkspaces: [Workspace]
    @Binding var selection: Set<UUID>
    @State private var search = ""

    /// Portraits filtered by the currently selected workspace.
    /// When "My Library" is selected (nil), all portraits are shown.
    private var portraits: [Portrait] {
        guard let wsID = appState.selectedWorkspaceID else {
            return allPortraits
        }
        let workspacePortraitIDs = Set(
            syncStates
                .filter { $0.workspaceID == wsID && $0.kind == .portrait }
                .map(\.itemID)
        )
        return allPortraits.filter { workspacePortraitIDs.contains($0.id) }
    }

    private var filtered: [Portrait] {
        guard !search.isEmpty else { return portraits }
        let q = search.lowercased()
        return portraits.filter {
            $0.name.lowercased().contains(q) || $0.tags.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(Loc.searchPlaceholder, text: $search)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(Color(.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding([.horizontal, .top], 12)

            if filtered.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: appState.isViewingWorkspace && portraits.isEmpty
                        ? "cloud" : "person.crop.rectangle",
                    description: Text(emptyDescription)
                )
                .frame(maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(filtered) { p in
                        PortraitRow(portrait: p, background: background(for: p))
                            .tag(p.id)
                            .contextMenu {
                                moveMenu(for: p)
                                Divider()
                                Button(Loc.delete, role: .destructive) {
                                    context.delete(p)
                                    selection.remove(p.id)
                                }
                            }
                    }
                }
                .listStyle(.sidebar)
            }

            SidebarUpdateCard()
        }
        .animation(.easeInOut(duration: 0.2), value: updater.state == .idle)
        .overlay {
            if appState.isProcessing {
                VStack(spacing: 8) {
                    if appState.batchTotal > 1 {
                        ProgressView(value: Double(appState.batchCompleted),
                                     total: Double(appState.batchTotal))
                            .frame(width: 120)
                        Text("\(appState.batchCompleted)/\(appState.batchTotal)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView(Loc.processing)
                    }
                }
                .padding()
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var emptyTitle: String {
        if !search.isEmpty { return Loc.noResults }
        if appState.isViewingWorkspace && portraits.isEmpty {
            return Loc.noPortraitsInWorkspace
        }
        return Loc.noPortraitsYet
    }

    private var emptyDescription: String {
        if !search.isEmpty { return Loc.adjustSearch }
        if appState.isViewingWorkspace && portraits.isEmpty {
            return Loc.addPortraitsHint
        }
        return Loc.importToStart
    }

    // MARK: - Move to workspace

    /// Workspaces available as move targets (excludes the currently viewed workspace).
    private var moveTargetWorkspaces: [Workspace] {
        allWorkspaces.filter { $0.id != appState.selectedWorkspaceID }
    }

    /// IDs affected by a right-click: if the clicked portrait is part of the
    /// current selection, act on the whole selection; otherwise just that one.
    private func affectedIDs(for portrait: Portrait) -> Set<UUID> {
        selection.contains(portrait.id) ? selection : [portrait.id]
    }

    @ViewBuilder
    private func moveMenu(for portrait: Portrait) -> some View {
        let targets = moveTargetWorkspaces
        if targets.isEmpty {
            Button(Loc.noWorkspacesAvailable) {}
                .disabled(true)
        } else {
            Menu(Loc.moveTo) {
                ForEach(targets) { workspace in
                    Button(workspace.name) {
                        movePortraits(affectedIDs(for: portrait), to: workspace)
                    }
                }
            }
        }
    }

    /// Moves portraits to the target workspace by creating SyncState entries
    /// and removing them from the current workspace (if viewing one).
    private func movePortraits(_ ids: Set<UUID>, to workspace: Workspace) {
        let currentWS = appState.selectedWorkspaceID

        for id in ids {
            // Remove from current workspace if we're inside one
            if let currentWS {
                let toRemove = syncStates.filter {
                    $0.itemID == id && $0.workspaceID == currentWS && $0.kind == .portrait
                }
                for state in toRemove {
                    context.delete(state)
                }
            }

            // Add to target workspace (skip if already there)
            let alreadyInTarget = syncStates.contains {
                $0.itemID == id && $0.workspaceID == workspace.id && $0.kind == .portrait
            }
            if !alreadyInTarget {
                let newState = SyncState(
                    itemID: id,
                    itemKind: .portrait,
                    workspaceID: workspace.id
                )
                context.insert(newState)
            }
        }

        // Clear selection for moved items (they'll disappear from current view)
        if currentWS != nil {
            selection.subtract(ids)
        }
    }

    /// Resolves the background each portrait should be drawn against.
    /// Honours the per-portrait `backgroundPresetID` so the thumbnail updates
    /// the moment the user picks a different background in the editor.
    private func background(for portrait: Portrait) -> BackgroundPreset? {
        if let id = portrait.backgroundPresetID,
           let bg = backgrounds.first(where: { $0.id == id }) {
            return bg
        }
        return backgrounds.first(where: { $0.isDefault }) ?? backgrounds.first
    }
}

private struct PortraitRow: View {
    let portrait: Portrait
    let background: BackgroundPreset?
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 10) {
            Thumbnail(portrait: portrait, background: background)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(portrait.name.isEmpty ? Loc.unnamed : portrait.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if !portrait.tags.isEmpty {
                    Text(portrait.tags)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

private struct Thumbnail: View {
    let portrait: Portrait
    let background: BackgroundPreset?

    var body: some View {
        // Reuse the same live preview composition as the editor for visual consistency.
        CanvasPreview(portrait: portrait, background: background)
    }
}
