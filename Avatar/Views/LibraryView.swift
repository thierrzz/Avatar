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
                List(selection: $selection) {
                    ForEach(filtered) { p in
                        PortraitRow(portrait: p, background: background(for: p))
                            .tag(p.id)
                            .contextMenu {
                                Button(Loc.delete, role: .destructive) {
                                    context.delete(p)
                                    if selection == p.id { selection = nil }
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
                ProgressView(Loc.processing)
                    .padding()
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
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
