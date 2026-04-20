import SwiftUI
import SwiftData

struct BatchEditorView: View {
    @Environment(AppState.self) private var appState
    @Environment(ModelManager.self) private var modelManager
    @Environment(\.modelContext) private var context
    @Environment(\.undoManager) private var undoManager
    @Query(sort: \Portrait.updatedAt, order: .reverse) private var allPortraits: [Portrait]
    @Query(sort: \BackgroundPreset.createdAt) private var backgrounds: [BackgroundPreset]

    @State private var deltas = BatchAdjustmentDeltas()
    @State private var showDeleteConfirm = false
    @State private var showAlignConfirm = false
    @State private var showInspector = true

    private var selectedPortraits: [Portrait] {
        let ids = appState.selectedPortraitIDs
        return allPortraits.filter { ids.contains($0.id) }
    }

    var body: some View {
        thumbnailGrid
            .inspector(isPresented: $showInspector) {
                controlsPanel
                    .inspectorColumnWidth(min: 320, ideal: 340, max: 400)
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        showInspector.toggle()
                    } label: {
                        Label(Loc.inspector, systemImage: "sidebar.trailing")
                    }
                    .help(Loc.inspectorHelp)
                }
            }
    }

    // MARK: - Thumbnail Grid

    private var thumbnailGrid: some View {
        GeometryReader { geo in
            ZStack {
                Color(.windowBackgroundColor)

                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 12)],
                              spacing: 12) {
                        ForEach(selectedPortraits) { portrait in
                            VStack(spacing: 4) {
                                CanvasPreview(portrait: portrait, background: background(for: portrait))
                                    .frame(width: 120, height: 120)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                                Text(portrait.name.isEmpty ? Loc.unnamed : portrait.name)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(24)
                }

                // Batch progress overlay.
                if appState.isProcessing && appState.batchTotal > 1 {
                    batchProgressOverlay
                }
            }
        }
    }

    private var batchProgressOverlay: some View {
        VStack(spacing: 12) {
            ProgressView(value: Double(appState.batchCompleted),
                         total: Double(appState.batchTotal))
                .frame(width: 200)
            Text("\(appState.batchCompleted)/\(appState.batchTotal)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(Loc.cancel) {
                appState.isBatchCancelled = true
            }
            .buttonStyle(.bordered)
        }
        .padding(24)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Controls Panel

    private var controlsPanel: some View {
        let portraits = selectedPortraits
        let count = portraits.count

        return Form {
            // MARK: Selection Info
            Section {
                Label(Loc.selectedCount(count), systemImage: "photo.on.rectangle.angled")
            }

            // MARK: Background
            Section {
                BatchBackgroundPicker(
                    portraits: portraits,
                    backgrounds: backgrounds
                )
            } header: {
                Text(Loc.background)
            }

            // MARK: Alignment
            Section {
                Button {
                    showAlignConfirm = true
                } label: {
                    Label(Loc.batchAlign, systemImage: "face.smiling")
                }
                .disabled(appState.isProcessing)
            } header: {
                Text(Loc.positionScale)
            }

            // MARK: Edit
            Section {
                // Upscale
                let upscaleEligible = portraits.filter { !$0.isUpscaled && $0.originalImageData != nil }
                Button {
                    BatchOperations.upscale(portraits: portraits, context: context,
                                            appState: appState, modelManager: modelManager)
                } label: {
                    Label(Loc.batchUpscaleCount(upscaleEligible.count, count),
                          systemImage: "arrow.up.left.and.arrow.down.right.magnifyingglass")
                }
                .disabled(upscaleEligible.isEmpty || appState.isProcessing)

                // Magic Retouch
                let retouchEligible = portraits.filter { !$0.isMagicRetouched && $0.cutoutPNG != nil }
                let retouched = portraits.filter(\.isMagicRetouched)

                Button {
                    BatchOperations.magicRetouch(portraits: portraits, context: context,
                                                 appState: appState, modelManager: modelManager)
                } label: {
                    Label(Loc.batchRetouchCount(retouchEligible.count, count),
                          systemImage: "wand.and.sparkles")
                }
                .disabled(retouchEligible.isEmpty || appState.isProcessing)

                if !retouched.isEmpty {
                    Button {
                        BatchOperations.undoMagicRetouch(portraits: portraits, context: context,
                                                         appState: appState)
                    } label: {
                        Label(Loc.batchUndoRetouch(retouched.count),
                              systemImage: "wand.and.sparkles.inverse")
                    }
                    .disabled(appState.isProcessing)
                }
            } header: {
                Text(Loc.edit)
            }

            // MARK: Adjustments
            Section {
                DisclosureGroup(Loc.colorAdjustments) {
                    deltaSlider(Loc.exposure,    value: $deltas.exposure,    range: -2...2,       format: "%+.2f")
                    deltaSlider(Loc.contrast,    value: $deltas.contrast,    range: -0.5...0.5,   format: "%+.2f")
                    deltaSlider(Loc.tint,        value: $deltas.tint,        range: -100...100,   format: "%+.0f")
                    deltaSlider(Loc.saturation,  value: $deltas.saturation,  range: -1...1,       format: "%+.2f")
                    deltaSlider(Loc.temperature, value: $deltas.temperature, range: -2000...2000, format: "%+.0fK")
                    deltaSlider(Loc.highlights,  value: $deltas.highlights,  range: -1...1,       format: "%+.2f")
                    deltaSlider(Loc.shadows,     value: $deltas.shadows,     range: -1...1,       format: "%+.2f")

                    HStack {
                        Button(Loc.batchApplyAdjustments) {
                            BatchOperations.applyAdjustments(
                                portraits: portraits, deltas: deltas,
                                context: context, undoManager: undoManager,
                                appState: appState)
                            deltas = BatchAdjustmentDeltas()
                        }
                        .disabled(deltas.isZero)

                        Spacer()

                        Button(Loc.batchResetAdjustments) {
                            BatchOperations.resetAdjustments(
                                portraits: portraits,
                                context: context, undoManager: undoManager,
                                appState: appState)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }

            // MARK: Delete
            Section {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label(Loc.batchDelete(count), systemImage: "trash")
                }
            }
        }
        .formStyle(.grouped)
        .disabled(appState.isProcessing)
        .confirmationDialog(
            Loc.batchDeleteConfirm(count),
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(Loc.batchDelete(count), role: .destructive) {
                BatchOperations.delete(portraits: portraits, context: context, appState: appState)
            }
            Button(Loc.cancel, role: .cancel) { }
        }
        .confirmationDialog(
            Loc.batchAlignQuestion(count),
            isPresented: $showAlignConfirm,
            titleVisibility: .visible
        ) {
            Button(Loc.batchAlign, role: .destructive) {
                let _ = BatchOperations.autoAlign(
                    portraits: portraits, context: context,
                    undoManager: undoManager, appState: appState)
            }
            Button(Loc.cancel, role: .cancel) { }
        }
    }

    // MARK: - Delta Slider

    private func deltaSlider(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack {
                Slider(value: value, in: range)
                Text(String(format: format, value.wrappedValue))
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 60, alignment: .trailing)
            }
        }
    }

    // MARK: - Helpers

    private func background(for portrait: Portrait) -> BackgroundPreset? {
        if let id = portrait.backgroundPresetID,
           let bg = backgrounds.first(where: { $0.id == id }) {
            return bg
        }
        return backgrounds.first(where: { $0.isDefault }) ?? backgrounds.first
    }
}

// MARK: - Batch Background Picker

/// A background picker that applies the selection to all given portraits.
private struct BatchBackgroundPicker: View {
    let portraits: [Portrait]
    let backgrounds: [BackgroundPreset]
    @Environment(\.modelContext) private var context
    @Environment(\.undoManager) private var undoManager
    @Environment(AppState.self) private var appState
    @State private var showAddPopover = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(backgrounds) { bg in
                    BackgroundChip(
                        preset: bg,
                        isSelected: allHaveBackground(bg),
                        onSelect: { select(bg) },
                        onSetDefault: { setDefault(bg) },
                        onDelete: { delete(bg) }
                    )
                }
                AddBackgroundButton(showPopover: $showAddPopover) { kind in
                    addNewBackground(kind)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func allHaveBackground(_ bg: BackgroundPreset) -> Bool {
        portraits.allSatisfy { $0.backgroundPresetID == bg.id }
    }

    private func select(_ bg: BackgroundPreset) {
        BatchOperations.setBackground(portraits: portraits, presetID: bg.id,
                                      context: context, undoManager: undoManager,
                                      appState: appState)
    }

    private func setDefault(_ bg: BackgroundPreset) {
        for other in backgrounds { other.isDefault = false }
        bg.isDefault = true
        try? context.save()
    }

    private func delete(_ bg: BackgroundPreset) {
        for p in portraits where p.backgroundPresetID == bg.id {
            p.backgroundPresetID = nil
        }
        appState.invalidateBackground(bg)
        context.delete(bg)
        try? context.save()
    }

    private func addNewBackground(_ kind: AddBackgroundKind) {
        switch kind {
        case .image:
            pickImageFile()
        case .color(let r, let g, let b):
            let bg = BackgroundPreset(
                name: Loc.color,
                kind: .color,
                color: (r, g, b, 1.0)
            )
            context.insert(bg)
            try? context.save()
            select(bg)
        }
    }

    private func pickImageFile() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url,
           let data = try? Data(contentsOf: url) {
            let name = url.deletingPathExtension().lastPathComponent
            let bg = BackgroundPreset(name: name, kind: .image, imageData: data)
            context.insert(bg)
            try? context.save()
            select(bg)
        }
        #endif
    }
}
