import SwiftUI
import SwiftData

struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var appState
    @Environment(UpdateManager.self) private var updater
    @Query(sort: \Portrait.updatedAt, order: .reverse) private var portraits: [Portrait]
    @Query private var backgrounds: [BackgroundPreset]
    @Binding var selection: UUID?
    @State private var search = ""
    @State private var multiSelection: Set<UUID> = []

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
                    portraits.isEmpty ? Loc.noPortraitsYet : Loc.noResults,
                    systemImage: "person.crop.rectangle",
                    description: Text(portraits.isEmpty
                        ? Loc.importToStart
                        : Loc.adjustSearch)
                )
                .frame(maxHeight: .infinity)
            } else {
                List(selection: $multiSelection) {
                    ForEach(filtered) { p in
                        PortraitRow(portrait: p, background: background(for: p))
                            .tag(p.id)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                            .contextMenu {
                                let targets = contextTargets(for: p)
                                Button(targets.count > 1
                                       ? "\(Loc.delete) \(targets.count) \(Loc.portraitsPlural)"
                                       : Loc.delete,
                                       role: .destructive) {
                                    delete(targets)
                                }
                            }
                    }
                }
                .animation(.easeOut(duration: 0.2), value: filtered.map(\.id))
                .listStyle(.sidebar)
                .onDeleteCommand {
                    delete(filtered.filter { multiSelection.contains($0.id) })
                }
            }

            DebugProToggle()
            SidebarUpdateCard()
        }
        .onAppear {
            multiSelection = selection.map { [$0] } ?? []
        }
        .onChange(of: multiSelection) { _, newValue in
            let single: UUID? = newValue.count == 1 ? newValue.first : nil
            if selection != single { selection = single }
        }
        .onChange(of: selection) { _, newValue in
            let desired: Set<UUID> = newValue.map { [$0] } ?? []
            if multiSelection.count <= 1 && multiSelection != desired {
                multiSelection = desired
            }
        }
        .animation(.easeOut(duration: 0.3), value: updater.state)
    }

    private func contextTargets(for portrait: Portrait) -> [Portrait] {
        if multiSelection.contains(portrait.id) && multiSelection.count > 1 {
            return filtered.filter { multiSelection.contains($0.id) }
        }
        return [portrait]
    }

    private func delete(_ portraits: [Portrait]) {
        guard !portraits.isEmpty else { return }
        let ids = Set(portraits.map(\.id))
        for p in portraits { context.delete(p) }
        multiSelection.subtract(ids)
        if let sel = selection, ids.contains(sel) { selection = nil }
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
