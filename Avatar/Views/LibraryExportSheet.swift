import SwiftUI
import SwiftData

struct LibraryExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \Portrait.updatedAt, order: .reverse) private var portraits: [Portrait]
    @Query(sort: \BackgroundPreset.createdAt) private var backgrounds: [BackgroundPreset]

    @State private var selectedIDs: Set<UUID> = []
    @State private var includeBackgrounds = true
    @State private var includePresets = true
    @State private var isExporting = false
    @State private var progress: Double = 0
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(Loc.exportLibraryTitle).font(.headline)
                Spacer()
                Button(selectedIDs.count == portraits.count ? Loc.deselectAll : Loc.selectAll) {
                    if selectedIDs.count == portraits.count {
                        selectedIDs.removeAll()
                    } else {
                        selectedIDs = Set(portraits.map(\.id))
                    }
                }
                .buttonStyle(.link)
            }
            .padding()

            Divider()

            // Portrait grid
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 8) {
                    ForEach(portraits) { portrait in
                        PortraitSelectionCell(
                            portrait: portrait,
                            isSelected: selectedIDs.contains(portrait.id)
                        )
                        .onTapGesture {
                            if selectedIDs.contains(portrait.id) {
                                selectedIDs.remove(portrait.id)
                            } else {
                                selectedIDs.insert(portrait.id)
                            }
                        }
                    }
                }
                .padding()
            }
            .frame(minHeight: 200)

            Divider()

            // Options
            VStack(alignment: .leading, spacing: 8) {
                Toggle(Loc.includeBackgrounds, isOn: $includeBackgrounds)
                Toggle(Loc.includeExportPresets, isOn: $includePresets)

                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            // Actions
            HStack {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Spacer()

                if isExporting {
                    ProgressView(value: progress)
                        .frame(width: 120)
                    Text(Loc.exporting)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button(Loc.cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button(Loc.export) { startExport() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(selectedIDs.isEmpty)
                }
            }
            .padding()
        }
        .frame(width: 480, height: 520)
        .onAppear {
            selectedIDs = Set(portraits.map(\.id))
        }
    }

    private var summaryText: String {
        let pCount = Loc.portraitsCount(selectedIDs.count)
        let bCount = includeBackgrounds ? ", \(Loc.backgroundsCount(backgrounds.count))" : ""

        let selectedPortraits = portraits.filter { selectedIDs.contains($0.id) }
        let size = LibraryArchiver.estimateSize(
            portraits: selectedPortraits,
            backgrounds: includeBackgrounds ? backgrounds : [],
            includeBackgrounds: includeBackgrounds,
            includeExportPresets: includePresets
        )
        let sizeStr = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        return "\(pCount)\(bCount) — \(Loc.estimatedSize(sizeStr))"
    }

    private func startExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.avatarLibrary]
        panel.nameFieldStringValue = "Avatar Library.avatarlib"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        isExporting = true
        errorMessage = nil

        Task {
            do {
                try await LibraryArchiver.export(
                    to: url,
                    options: .init(
                        portraitIDs: selectedIDs,
                        includeBackgrounds: includeBackgrounds,
                        includeExportPresets: includePresets
                    ),
                    context: context,
                    progress: { self.progress = $0 }
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isExporting = false
            }
        }
    }
}

// MARK: - Selection cell

private struct PortraitSelectionCell: View {
    let portrait: Portrait
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                if let data = portrait.cutoutPNG,
                   let nsImage = NSImage(data: data) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.quaternary)
                        .frame(width: 72, height: 72)
                        .overlay {
                            Image(systemName: "person.fill")
                                .foregroundStyle(.tertiary)
                        }
                }

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? .blue : .secondary)
                    .background(Circle().fill(.white).padding(2))
                    .offset(x: 4, y: -4)
            }

            Text(portrait.name.isEmpty ? Loc.unnamed : portrait.name)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .opacity(isSelected ? 1 : 0.5)
    }
}
