import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

struct EditorView: View {
    @Bindable var portrait: Portrait
    @Environment(\.modelContext) private var context
    @Environment(\.undoManager) private var undoManager
    @Environment(AppState.self) private var appState
    @Environment(ModelManager.self) private var modelManager
    @Environment(UpscaleModelManager.self) private var upscaleManager
    @Query(sort: \BackgroundPreset.createdAt) private var backgrounds: [BackgroundPreset]
    @Query private var allPortraits: [Portrait]

    @State private var dragStart: CGSize? = nil
    @State private var dragUndoSnapshot: PortraitUndoManager.Snapshot? = nil
    /// Shared snapshot for any slider interaction (scale or adjustments).
    /// Captured on first change, committed when a different action starts.
    @State private var sliderUndoSnapshot: PortraitUndoManager.Snapshot? = nil
    @State private var sliderActionName: String? = nil
    @State private var showExport = false
    @State private var showBulkAlignConfirm = false
    @State private var bulkSkippedCount: Int? = nil
    @State private var showDeleteConfirm = false
    @State private var showUpscalePopover = false
    @State private var pendingUpscaleAfterInstall = false

    /// Which pane the right-hand inspector is showing. Persisted across launches.
    @AppStorage("editorTab") private var editorTab: EditorTab = .portrait

    enum EditorTab: String, CaseIterable, Identifiable {
        case portrait, adjust
        var id: String { rawValue }
        var label: String {
            switch self {
            case .portrait: return Loc.tabPortrait
            case .adjust:   return Loc.tabAdjust
            }
        }
    }

    /// Shows a semi-transparent alignment guide (eye markers + head oval)
    /// on the canvas so you can visually verify that all portraits share the
    /// same eye height and head size. Persisted across app launches.
    @AppStorage("showAlignmentGuide") private var showAlignmentGuide = false

    // Drag/snap state
    @State private var isDragging = false
    @State private var snappedX = false
    @State private var snappedY = false
    /// Last haptic tick position in canvas units — used to emit a soft tick
    /// every `hapticStep` units during a drag (Premiere-Pro style continuous feel).
    @State private var lastHapticTickX: Double = 0
    @State private var lastHapticTickY: Double = 0
    private let hapticStep: Double = 24

    /// Canvas view-zoom multiplier. Pinch = zoom the editing canvas in/out
    /// without touching the underlying portrait transform. 1.0 = fit window.
    @State private var canvasZoom: Double = 1.0

    /// Tap the image to show bounding-box handles for proportional scaling.
    /// Tap elsewhere, press Escape, or start a drag to dismiss.
    @State private var imageSelected = false

    // Drag-and-drop of a NEW photo onto the editor: lets the user start a fresh
    // portrait without going back to an empty state. ImportFlow auto-selects
    // the new portrait, so the editor switches to it on completion.
    @State private var isDropping = false
    @State private var showInspector = true
    #if os(macOS)
    private let haptics = NSHapticFeedbackManager.defaultPerformer
    #endif

    // Snap thresholds in canvas units (1024 = full canvas).
    private let snapEnter: Double = 12
    private let snapExit: Double = 24

    private var selectedBackground: BackgroundPreset? {
        if let id = portrait.backgroundPresetID,
           let bg = backgrounds.first(where: { $0.id == id }) {
            return bg
        }
        return backgrounds.first(where: { $0.isDefault }) ?? backgrounds.first
    }

    var body: some View {
        canvasArea
            .inspector(isPresented: $showInspector) {
                controlsPanel
                    .inspectorColumnWidth(min: 320, ideal: 340, max: 400)
            }
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button {
                        commitSliderUndo()
                        undoManager?.undo()
                    } label: {
                        Label(Loc.undo, systemImage: "arrow.uturn.backward")
                    }
                    .disabled(!(undoManager?.canUndo ?? false) && sliderUndoSnapshot == nil)
                    .help(Loc.undoHelp)

                    Button {
                        commitSliderUndo()
                        undoManager?.redo()
                    } label: {
                        Label(Loc.redo, systemImage: "arrow.uturn.forward")
                    }
                    .disabled(!(undoManager?.canRedo ?? false))
                    .help(Loc.redoHelp)
                }

                ToolbarItemGroup(placement: .primaryAction) {
                    Toggle(isOn: $showAlignmentGuide) {
                        Label(Loc.alignmentGuide, systemImage: "face.dashed")
                    }
                    .help(Loc.alignmentGuideHelp)

                    Button {
                        showInspector.toggle()
                    } label: {
                        Label(Loc.inspector, systemImage: "sidebar.trailing")
                    }
                    .help(Loc.inspectorHelp)

                    Button {
                        showExport = true
                    } label: {
                        Label(Loc.export, systemImage: "square.and.arrow.up")
                    }

                    Menu {
                        Button {
                            showBulkAlignConfirm = true
                        } label: {
                            Label(Loc.alignAllPortraits, systemImage: "rectangle.3.group")
                        }
                        .disabled(alignableCount < 2)

                        Divider()

                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label(Loc.deletePortrait, systemImage: "trash")
                        }
                    } label: {
                        Label(Loc.more, systemImage: "ellipsis.circle")
                    }
                    .help(Loc.moreHelp)
                }
            }
            .sheet(isPresented: $showExport) {
                ExportSheet(portrait: portrait, background: selectedBackground)
            }
            .onDrop(of: [.fileURL, .image], isTargeted: $isDropping) { providers in
                PortraitDropHandler.handle(providers: providers, context: context, appState: appState,
                                           modelManager: modelManager)
            }
            .overlay {
                if isDropping {
                    NewPhotoDropOverlay()
                        .allowsHitTesting(false)
                        .transition(.opacity)
                } else if appState.isProcessing {
                    ProcessingOverlay()
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: isDropping)
            .animation(.easeOut(duration: 0.15), value: appState.isProcessing)
    }

    // MARK: - Canvas

    private var canvasArea: some View {
        GeometryReader { geo in
            // Canvas padding scales down on small windows so the preview
            // doesn't shrink to nothing when the controls panel takes its share.
            let shortSide = min(geo.size.width, geo.size.height)
            let padding: CGFloat = shortSide > 420 ? 48 : 16
            let fitSide = max(40, shortSide - padding)
            // User-controlled canvas zoom (pinch) multiplies the fit-size.
            let side = max(40, fitSide * canvasZoom)
            ZStack {
                // Background tap = deselect (dismiss handles).
                Color(.windowBackgroundColor)
                    .contentShape(Rectangle())
                    .onTapGesture { imageSelected = false }

                ZStack {
                    ZStack {
                        CanvasPreview(
                            portrait: portrait,
                            background: selectedBackground
                        )
                        AlignmentGuideOverlay(isVisible: showAlignmentGuide)
                        GuideLinesOverlay(
                            isVisible: isDragging,
                            snappedX: snappedX,
                            snappedY: snappedY
                        )
                    }
                    // Editor always shows the square canvas; the circular crop
                    // is applied at export time based on the chosen preset.
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
                    .contentShape(RoundedRectangle(cornerRadius: 4))
                    // Tap on image = select (show handles).
                    .onTapGesture { imageSelected = true }
                    .gesture(dragGesture(canvasSide: side))

                    // Bounding-box handles only visible+interactive when selected.
                    BoundingBoxOverlay(
                        portrait: portrait,
                        canvasSide: side,
                        cutoutSize: cutoutSize,
                        isVisible: imageSelected,
                        onCommit: { try? context.save() }
                    )
                }
                .frame(width: side, height: side)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(magnifyGesture)
            .onExitCommand { imageSelected = false }
            .overlay(alignment: .bottomTrailing) {
                dimensionsCaption
                    .padding(10)
            }
        }
    }

    /// Live "W × H px" readout showing the current cutout pixel size.
    /// Doubles/quadruples after an AI upscale so the user can see the effect.
    @ViewBuilder
    private var dimensionsCaption: some View {
        let size = cutoutSize
        if size.width > 0, size.height > 0 {
            Text(Loc.dimensionsLabel(Int(size.width), Int(size.height)))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }

    /// Current cutout pixel size (or zero if not yet loaded). Used by the
    /// bounding-box overlay to place handles.
    private var cutoutSize: CGSize {
        guard let cg = appState.cutout(for: portrait) else { return .zero }
        return CGSize(width: cg.width, height: cg.height)
    }

    private func dragGesture(canvasSide: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStart == nil {
                    commitSliderUndo()
                    dragStart = CGSize(width: portrait.offsetX, height: portrait.offsetY)
                    dragUndoSnapshot = PortraitUndoManager.snapshot(of: portrait)
                    isDragging = true
                    imageSelected = false   // dismiss bounding-box handles on drag
                    lastHapticTickX = portrait.offsetX
                    lastHapticTickY = portrait.offsetY
                }

                // Map screen-space delta to canvas-space (canvas is 1024 units wide).
                let factor = CanvasConstants.editCanvas.width / canvasSide
                var dx = value.translation.width * factor
                var dy = value.translation.height * factor

                // Shift = constrain to dominant axis (Figma/Instagram style).
                if NSEvent.modifierFlags.contains(.shift) {
                    if abs(value.translation.width) >= abs(value.translation.height) {
                        dy = 0
                    } else {
                        dx = 0
                    }
                }

                let rawX = dragStart!.width + dx
                let rawY = dragStart!.height + dy

                // Snap-to-center with hysteresis: enter at 12, release at 24 canvas units.
                let canvasCenter = CanvasConstants.editCanvas.width / 2
                var newX = rawX
                var newY = rawY
                var newSnappedX = snappedX
                var newSnappedY = snappedY

                if let cutout = appState.cutout(for: portrait) {
                    let imgW = Double(cutout.width) * portrait.scale
                    let imgH = Double(cutout.height) * portrait.scale
                    let rawCenterX = rawX + imgW / 2
                    let rawCenterY = rawY + imgH / 2

                    let thresholdX = snappedX ? snapExit : snapEnter
                    if abs(rawCenterX - canvasCenter) < thresholdX {
                        newX = canvasCenter - imgW / 2
                        newSnappedX = true
                    } else {
                        newSnappedX = false
                    }

                    let thresholdY = snappedY ? snapExit : snapEnter
                    if abs(rawCenterY - canvasCenter) < thresholdY {
                        newY = canvasCenter - imgH / 2
                        newSnappedY = true
                    } else {
                        newSnappedY = false
                    }
                }

                // Snap-zone transitions get the stronger .alignment tick (the
                // system "click into place" feel). Plain movement gets a soft
                // .generic tick every `hapticStep` canvas units so the drag has
                // the continuous texture Premiere Pro's timeline has.
                let snapChanged = (newSnappedX != snappedX) || (newSnappedY != snappedY)
                if snapChanged {
                    #if os(macOS)
                    haptics.perform(.alignment, performanceTime: .now)
                    #endif
                    lastHapticTickX = newX
                    lastHapticTickY = newY
                } else {
                    if abs(newX - lastHapticTickX) >= hapticStep ||
                       abs(newY - lastHapticTickY) >= hapticStep {
                        #if os(macOS)
                        haptics.perform(.generic, performanceTime: .now)
                        #endif
                        lastHapticTickX = newX
                        lastHapticTickY = newY
                    }
                }
                snappedX = newSnappedX
                snappedY = newSnappedY

                portrait.offsetX = newX
                portrait.offsetY = newY
                portrait.updatedAt = Date()
            }
            .onEnded { _ in
                if let before = dragUndoSnapshot {
                    try? context.save()
                    PortraitUndoManager.registerFromSnapshots(
                        before: before,
                        after: PortraitUndoManager.snapshot(of: portrait),
                        context: context,
                        undoManager: undoManager,
                        appState: appState,
                        actionName: Loc.moveAction
                    )
                } else {
                    try? context.save()
                }
                dragStart = nil
                dragUndoSnapshot = nil
                isDragging = false
                snappedX = false
                snappedY = false
            }
    }

    /// Pinch zooms the CANVAS viewport (not the portrait image). The portrait
    /// is scaled by dragging the bounding-box handles instead.
    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let delta = Double(value) / max(0.0001, lastMag)
                canvasZoom = max(0.3, min(4.0, canvasZoom * delta))
                lastMag = Double(value)
            }
            .onEnded { _ in
                lastMag = 1.0
            }
    }
    @State private var lastMag: Double = 1.0

    // MARK: - Controls

    private var controlsPanel: some View {
        VStack(spacing: 0) {
            Picker("", selection: $editorTab) {
                ForEach(EditorTab.allCases) { tab in
                    Text(tab.label).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)

            Form {
                switch editorTab {
                case .portrait: portraitTab
                case .adjust:   adjustTab
                }
            }
            .formStyle(.grouped)
        }
        .confirmationDialog(
            Loc.alignAllQuestion,
            isPresented: $showBulkAlignConfirm,
            titleVisibility: .visible
        ) {
            Button(Loc.alignButton(alignableCount), role: .destructive) { bulkAlign() }
            Button(Loc.cancel, role: .cancel) { }
        } message: {
            Text(Loc.alignConfirmMessage(alignableCount))
        }
        .confirmationDialog(
            Loc.deleteQuestion,
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(Loc.deletePortrait, role: .destructive) {
                context.delete(portrait)
                appState.selectedPortraitID = nil
            }
            Button(Loc.cancel, role: .cancel) { }
        } message: {
            Text(Loc.deleteMessage)
        }
        .alert(Loc.alignComplete, isPresented: Binding(
            get: { bulkSkippedCount != nil },
            set: { if !$0 { bulkSkippedCount = nil } }
        )) {
            Button(Loc.ok) { bulkSkippedCount = nil }
        } message: {
            if let n = bulkSkippedCount {
                Text(Loc.skippedPortraits(n))
            }
        }
    }

    // MARK: Portrait tab

    @ViewBuilder private var portraitTab: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                TextField(Loc.employeeName, text: $portrait.name)
                    .textFieldStyle(.plain)
                    .onChange(of: portrait.name) { _, _ in try? context.save() }
            }
            HStack(spacing: 8) {
                Image(systemName: "tag")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                TextField(Loc.role, text: $portrait.tags)
                    .textFieldStyle(.plain)
                    .onChange(of: portrait.tags) { _, _ in try? context.save() }
            }
        } header: {
            Text(Loc.info)
        }

        Section {
            BackgroundPicker(portrait: portrait, backgrounds: backgrounds)
        } header: {
            Text(Loc.background)
        }

        Section {
            scaleControl
            Button {
                autoAlign()
            } label: {
                Label(Loc.autoAlignFace, systemImage: "face.smiling")
            }
            .disabled(portrait.faceRect == .zero)
        } header: {
            Text(Loc.positionScale)
        }

        enhanceSection
    }

    private var scaleControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    stepScale(by: -0.1)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help(Loc.zoomOut)
                .disabled(portrait.scale <= 0.05)

                ZStack {
                    Slider(
                        value: Binding(
                            get: { portrait.scale },
                            set: {
                                trackSliderUndo(actionName: Loc.scale)
                                portrait.scale = $0
                                portrait.updatedAt = Date()
                                try? context.save()
                            }
                        ),
                        in: 0.05...4.0
                    )
                    // "Actual size" tick at 1.0x on the 0.05…4.0 range.
                    GeometryReader { geo in
                        let fraction = (1.0 - 0.05) / (4.0 - 0.05)
                        Rectangle()
                            .fill(Color.secondary.opacity(0.45))
                            .frame(width: 1.5, height: 6)
                            .position(x: geo.size.width * fraction, y: geo.size.height / 2)
                            .help(Loc.actualSize)
                    }
                    .allowsHitTesting(false)
                }

                Button {
                    stepScale(by: 0.1)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help(Loc.zoomIn)
                .disabled(portrait.scale >= 4.0)

                Text(String(format: "%.2fx", portrait.scale))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
        }
    }

    private func stepScale(by delta: Double) {
        trackSliderUndo(actionName: Loc.scale)
        portrait.scale = min(4.0, max(0.05, portrait.scale + delta))
        portrait.updatedAt = Date()
        try? context.save()
        #if os(macOS)
        haptics.perform(.generic, performanceTime: .now)
        #endif
    }

    // MARK: Enhance section (lives inside the Portrait tab)

    @ViewBuilder private var enhanceSection: some View {
        Section {
            enhanceCard(
                title: Loc.reCutout,
                systemImage: "wand.and.stars",
                disabled: portrait.originalImageData == nil || appState.isProcessing,
                help: modelManager.isAvailable && modelManager.useAdvancedModel
                    ? Loc.reCutoutHelpAdvanced : Loc.reCutoutHelpApple
            ) {
                ImportFlow.reprocess(portrait: portrait, context: context, appState: appState,
                                     modelManager: modelManager)
            }

            upscaleEnhanceCard()

            enhanceCard(
                title: portrait.isMagicRetouched ? Loc.magicRetouchUndo : Loc.magicRetouch,
                systemImage: portrait.isMagicRetouched ? "arrow.uturn.backward" : "wand.and.sparkles",
                disabled: portrait.cutoutPNG == nil || appState.isProcessing,
                help: portrait.isMagicRetouched ? Loc.magicRetouchUndoHelp : Loc.magicRetouchHelp,
                active: portrait.isMagicRetouched
            ) {
                if portrait.isMagicRetouched {
                    ImportFlow.undoMagicRetouch(portrait: portrait, context: context, appState: appState)
                } else {
                    ImportFlow.magicRetouch(portrait: portrait, context: context, appState: appState)
                }
            }

            // MARK: Extend Body (Pro feature)
            extendBodyCard

            if !modelManager.isAvailable && !modelManager.hintDismissed {
                AdvancedModelHint(modelManager: modelManager)
            }
        } header: {
            Text(Loc.edit)
        }
    }

    @ViewBuilder
    private func enhanceCard(
        title: String,
        systemImage: String,
        disabled: Bool,
        help: String,
        active: Bool = false,
        showProBadge: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(active ? Color.accentColor : Color.primary)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(active ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.12))
                    )
                    .symbolEffect(.bounce, value: active)
                Text(title)
                    .fontWeight(.medium)
                Spacer(minLength: 0)
                if showProBadge {
                    ProBadge()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .help(help)
    }

    @ViewBuilder
    private func upscaleEnhanceCard() -> some View {
        let modelReady = upscaleManager.isAnyInstalled
        let isDownloading = upscaleManager.isDownloading
        let hardDisabled = portrait.originalImageData == nil
            || appState.isProcessing
            || (portrait.isUpscaled && portrait.preUpscaleOriginalData == nil)
        let title: String = portrait.isUpscaled
            ? Loc.undoUpscale
            : Loc.upscaleNx(upscaleManager.selectedVariant.factor)
        let help: String = {
            if portrait.isUpscaled { return Loc.undoUpscaleHelp }
            if isDownloading { return Loc.upscaleHelpDownloading }
            if !modelReady { return Loc.upscaleHelpTapToInstall }
            return Loc.upscaleHelp
        }()
        let icon = portrait.isUpscaled
            ? "arrow.uturn.backward"
            : "arrow.up.left.and.arrow.down.right"

        Button {
            if portrait.isUpscaled {
                ImportFlow.undoUpscale(portrait: portrait, context: context, appState: appState)
            } else if modelReady {
                ImportFlow.upscale(portrait: portrait, context: context, appState: appState,
                                   modelManager: modelManager, upscaleManager: upscaleManager)
            } else {
                showUpscalePopover = true
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(portrait.isUpscaled ? Color.accentColor : Color.primary)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(portrait.isUpscaled
                                  ? Color.accentColor.opacity(0.15)
                                  : Color.secondary.opacity(0.12))
                    )
                    .symbolEffect(.bounce, value: portrait.isUpscaled)
                Text(title).fontWeight(.medium)
                Spacer(minLength: 0)
                if !portrait.isUpscaled && !modelReady {
                    if isDownloading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.secondary)
                            .symbolRenderingMode(.hierarchical)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(hardDisabled)
        .opacity(hardDisabled ? 0.45 : 1)
        .help(help)
        .popover(isPresented: $showUpscalePopover, arrowEdge: .trailing) {
            UpscaleInstallPopover(
                manager: upscaleManager,
                onRequestUpscale: {
                    if upscaleManager.isAnyInstalled {
                        showUpscalePopover = false
                        ImportFlow.upscale(portrait: portrait, context: context, appState: appState,
                                           modelManager: modelManager, upscaleManager: upscaleManager)
                    } else {
                        pendingUpscaleAfterInstall = true
                    }
                },
                onDismiss: {
                    showUpscalePopover = false
                    pendingUpscaleAfterInstall = false
                }
            )
        }
        .onChange(of: upscaleManager.isAnyInstalled) { _, nowInstalled in
            guard nowInstalled,
                  showUpscalePopover,
                  pendingUpscaleAfterInstall,
                  !portrait.isUpscaled else { return }
            pendingUpscaleAfterInstall = false
            showUpscalePopover = false
            ImportFlow.upscale(portrait: portrait, context: context, appState: appState,
                               modelManager: modelManager, upscaleManager: upscaleManager)
        }
    }

    // MARK: Extend Body (Pro feature)

    /// Auto-detect: body is considered "cropped" when the lowest body pixel
    /// sits within a small tolerance of the cutout's bottom edge.
    private var bodyNeedsExtension: Bool {
        let h = cutoutSize.height
        guard h > 0, portrait.bodyBottomY > 0 else { return false }
        return portrait.bodyBottomY >= Double(h) - 4
    }

    /// `true` when the user should see the paywall on tap (not signed in, no
    /// subscription, or out of credits). Pro users with credits go straight
    /// to the outpaint action.
    private var extendBodyNeedsUpgrade: Bool {
        !appState.proEntitlement.isPro || !appState.proEntitlement.hasCredits
    }

    @ViewBuilder
    private var extendBodyCard: some View {
        let isExtended = portrait.isBodyExtended
        let hasCutout = portrait.cutoutPNG != nil
        // Pro users: disable when cutout exists but body is already complete
        // (no work to do). Non-pro users: always clickable so the paywall can
        // sell them the feature.
        let disabled = !hasCutout
            || appState.isProcessing
            || (isExtended && portrait.preExtendBodyCutoutPNG == nil)
            || (!extendBodyNeedsUpgrade && !bodyNeedsExtension && !isExtended)

        let help: String = {
            if !hasCutout { return Loc.extendBodyNoCutout }
            if !appState.auth.isSignedIn { return Loc.extendBodyRequiresSignIn }
            if isExtended { return Loc.extendBodyUndoHelp }
            if !bodyNeedsExtension && !extendBodyNeedsUpgrade {
                return Loc.extendBodyAlreadyComplete
            }
            return Loc.extendBodyHelp
        }()

        enhanceCard(
            title: isExtended ? Loc.extendBodyUndo : Loc.extendBody,
            systemImage: isExtended ? "arrow.uturn.backward" : "person.crop.rectangle.badge.plus",
            disabled: disabled,
            help: help,
            active: isExtended,
            showProBadge: extendBodyNeedsUpgrade && !isExtended
        ) {
            if isExtended {
                ImportFlow.undoExtendBody(portrait: portrait, context: context, appState: appState)
            } else if !appState.auth.isSignedIn {
                appState.showSignInPrompt = true
                appState.showProUpgradeSheet = true
            } else if extendBodyNeedsUpgrade {
                appState.showProUpgradeSheet = true
            } else {
                ImportFlow.extendBody(portrait: portrait, context: context, appState: appState,
                                      modelManager: modelManager)
            }
        }
    }

    // MARK: Adjust tab

    @ViewBuilder private var adjustTab: some View {
        Section {
            adjustmentSlider(Loc.exposure,    icon: "sun.max",            value: $portrait.adjExposure,    range: -2...2,       neutral: 0,   displayScale: 50)
            adjustmentSlider(Loc.contrast,    icon: "circle.lefthalf.filled", value: $portrait.adjContrast,    range: 0.5...1.5,    neutral: 1,   displayScale: 200)
            adjustmentSlider(Loc.tint,        icon: "drop",               value: $portrait.adjTint,        range: -100...100,   neutral: 0,   displayScale: 1)
            adjustmentSlider(Loc.saturation,  icon: "paintpalette",       value: $portrait.adjSaturation,  range: 0...2,        neutral: 1,   displayScale: 100)
            adjustmentSlider(Loc.temperature, icon: "thermometer.medium", value: $portrait.adjTemperature, range: -2000...2000, neutral: 0,   displayScale: 0.05)
            adjustmentSlider(Loc.highlights,  icon: "sun.horizon",        value: $portrait.adjHighlights,  range: 0...2,        neutral: 1,   displayScale: 100)
            adjustmentSlider(Loc.shadows,     icon: "moon",               value: $portrait.adjShadows,     range: -1...1,       neutral: 0,   displayScale: 100)

            if isAdjustmentsDirty {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { resetAdjustments() }
                } label: {
                    Label(Loc.resetAdjustments, systemImage: "arrow.counterclockwise")
                }
                .foregroundStyle(.secondary)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        } header: {
            Text(Loc.colorAdjustments)
        }
    }

    private var isAdjustmentsDirty: Bool {
        portrait.adjExposure != 0 ||
        portrait.adjContrast != 1 ||
        portrait.adjTint != 0 ||
        portrait.adjSaturation != 1 ||
        portrait.adjTemperature != 0 ||
        portrait.adjHighlights != 1 ||
        portrait.adjShadows != 0
    }

    private func adjustmentSlider(
        _ label: String,
        icon: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        neutral: Double,
        displayScale: Double
    ) -> some View {
        let isDirty = value.wrappedValue != neutral
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                    .opacity(isDirty ? 1 : 0)
                    .animation(.easeOut(duration: 0.12), value: isDirty)
                Spacer()
                Text(String(format: "%+.0f", (value.wrappedValue - neutral) * displayScale))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .opacity(isDirty ? 1 : 0)
                    .animation(.easeOut(duration: 0.12), value: isDirty)
            }
            ZStack {
                Slider(
                    value: Binding(
                        get: { value.wrappedValue },
                        set: { newValue in
                            trackSliderUndo(actionName: label)
                            let snapThreshold = (range.upperBound - range.lowerBound) * 0.02
                            let wasOff = value.wrappedValue != neutral
                            let snapped = abs(newValue - neutral) < snapThreshold ? neutral : newValue
                            if snapped == neutral && wasOff {
                                #if os(macOS)
                                haptics.perform(.alignment, performanceTime: .now)
                                #endif
                            }
                            value.wrappedValue = snapped
                            portrait.updatedAt = Date()
                            appState.invalidateAdjusted(for: portrait)
                            try? context.save()
                        }
                    ),
                    in: range
                )
                // Subtle tick mark on the track at the neutral position.
                GeometryReader { geo in
                    let fraction = (neutral - range.lowerBound) / (range.upperBound - range.lowerBound)
                    Rectangle()
                        .fill(Color.secondary.opacity(isDirty ? 0 : 0.55))
                        .frame(width: 1.5, height: 6)
                        .position(x: geo.size.width * fraction, y: geo.size.height / 2)
                        .animation(.easeOut(duration: 0.12), value: isDirty)
                }
                .allowsHitTesting(false)
            }
        }
    }

    private func resetAdjustments() {
        commitSliderUndo()
        let before = PortraitUndoManager.snapshot(of: portrait)
        portrait.adjExposure = 0
        portrait.adjContrast = 1
        portrait.adjSaturation = 1
        portrait.adjTemperature = 0
        portrait.adjTint = 0
        portrait.adjHighlights = 1
        portrait.adjShadows = 0
        portrait.updatedAt = Date()
        appState.invalidateAdjusted(for: portrait)
        try? context.save()
        PortraitUndoManager.registerFromSnapshots(
            before: before,
            after: PortraitUndoManager.snapshot(of: portrait),
            context: context,
            undoManager: undoManager,
            appState: appState,
            actionName: Loc.resetAdjustments
        )
    }

    /// Captures a "before" snapshot on the first slider tick. The snapshot
    /// is committed as an undo step when a different action starts or when
    /// `commitSliderUndo()` is called explicitly.
    private func trackSliderUndo(actionName: String) {
        // If a previous slider session exists for a different action, commit it first.
        if sliderUndoSnapshot != nil, sliderActionName != actionName {
            commitSliderUndo()
        }
        if sliderUndoSnapshot == nil {
            sliderUndoSnapshot = PortraitUndoManager.snapshot(of: portrait)
            sliderActionName = actionName
        }
    }

    private func commitSliderUndo() {
        guard let before = sliderUndoSnapshot else { return }
        PortraitUndoManager.registerFromSnapshots(
            before: before,
            after: PortraitUndoManager.snapshot(of: portrait),
            context: context,
            undoManager: undoManager,
            appState: appState,
            actionName: sliderActionName ?? Loc.adjustment
        )
        sliderUndoSnapshot = nil
        sliderActionName = nil
    }

    private func autoAlign() {
        guard let cutout = appState.cutout(for: portrait) else { return }
        commitSliderUndo()
        let before = PortraitUndoManager.snapshot(of: portrait)
        let size = CGSize(width: cutout.width, height: cutout.height)
        let t = AutoAligner.computeTransform(
            faceRect: portrait.faceRect,
            eyeCenter: portrait.eyeCenter,
            interEyeDistance: CGFloat(portrait.interEyeDistance),
            cutoutSize: size,
            bodyBottomY: CGFloat(portrait.bodyBottomY))
        portrait.scale = Double(t.scale)
        portrait.offsetX = Double(t.offset.width)
        portrait.offsetY = Double(t.offset.height)
        portrait.updatedAt = Date()
        try? context.save()
        PortraitUndoManager.registerFromSnapshots(
            before: before,
            after: PortraitUndoManager.snapshot(of: portrait),
            context: context,
            undoManager: undoManager,
            appState: appState,
            actionName: Loc.autoAlignAction
        )
    }

    // MARK: - Bulk align

    private var alignableCount: Int {
        allPortraits.reduce(0) { $0 + ($1.faceRect == .zero ? 0 : 1) }
    }

    private func bulkAlign() {
        let result = BulkAligner.alignAll(
            portraits: allPortraits,
            appState: appState,
            context: context,
            undoManager: undoManager
        )
        if result.skipped > 0 { bulkSkippedCount = result.skipped }
    }
}

// MARK: - Bounding box with corner handles

/// Click-to-select overlay: tap the image to show a dashed outline and four
/// corner handles. Drag a handle to scale the portrait proportionally while
/// anchoring the opposite corner (Figma/Keynote style). Tap outside, press
/// Escape, or start a canvas-drag to dismiss. When hidden the overlay is
/// fully non-interactive so the canvas drag gesture works unimpeded.
struct BoundingBoxOverlay: View {
    @Bindable var portrait: Portrait
    let canvasSide: CGFloat
    let cutoutSize: CGSize
    let isVisible: Bool
    let onCommit: () -> Void

    @Environment(\.undoManager) private var undoManager
    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var appState

    @State private var dragStartScale: Double = 1
    @State private var dragStartOffsetX: Double = 0
    @State private var dragStartOffsetY: Double = 0
    @State private var activeHandle: Handle? = nil
    @State private var handleUndoSnapshot: PortraitUndoManager.Snapshot? = nil

    enum Handle: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    var body: some View {
        GeometryReader { geo in
            if cutoutSize.width > 0, cutoutSize.height > 0, canvasSide > 0 {
                let viewScale = geo.size.width / CanvasConstants.editCanvas.width
                let imgW = cutoutSize.width * portrait.scale * viewScale
                let imgH = cutoutSize.height * portrait.scale * viewScale
                let originX = portrait.offsetX * viewScale
                let originY = portrait.offsetY * viewScale

                ZStack {
                    // Dashed outline around the image bounds.
                    Rectangle()
                        .strokeBorder(
                            Color.accentColor.opacity(0.7),
                            style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                        )
                        .frame(width: imgW, height: imgH)
                        .position(x: originX + imgW / 2, y: originY + imgH / 2)
                        .allowsHitTesting(false)

                    ForEach(Handle.allCases, id: \.self) { handle in
                        handleView(handle,
                                   originX: originX,
                                   originY: originY,
                                   imgW: imgW,
                                   imgH: imgH,
                                   viewScale: viewScale)
                    }
                }
                .opacity(isVisible ? 1 : 0)
                .animation(.easeOut(duration: 0.12), value: isVisible)
            }
        }
        // Stable coordinate space for handle drag gestures — prevents
        // flickering caused by the handle moving mid-drag.
        .coordinateSpace(name: "boundingBox")
        // When hidden the overlay must not steal any gestures from the
        // canvas drag underneath.
        .allowsHitTesting(isVisible)
    }

    @ViewBuilder
    private func handleView(_ handle: Handle,
                            originX: CGFloat,
                            originY: CGFloat,
                            imgW: CGFloat,
                            imgH: CGFloat,
                            viewScale: CGFloat) -> some View {
        let pos = handlePosition(handle, originX: originX, originY: originY,
                                 imgW: imgW, imgH: imgH)
        Circle()
            .fill(Color.white)
            .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
            .frame(width: 12, height: 12)
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            // 44pt invisible hit area for comfortable grab.
            // contentShape BEFORE .position() so the hit area stays on
            // the corner, not the parent center.
            .contentShape(Circle().inset(by: -16))
            .position(pos)
            // Gesture AFTER .position() with a named coordinate space so
            // translations stay stable as the handle moves during scaling.
            .highPriorityGesture(handleDragGesture(handle, viewScale: viewScale))
    }

    private func handlePosition(_ handle: Handle,
                                originX: CGFloat, originY: CGFloat,
                                imgW: CGFloat, imgH: CGFloat) -> CGPoint {
        switch handle {
        case .topLeft:     return CGPoint(x: originX,        y: originY)
        case .topRight:    return CGPoint(x: originX + imgW, y: originY)
        case .bottomLeft:  return CGPoint(x: originX,        y: originY + imgH)
        case .bottomRight: return CGPoint(x: originX + imgW, y: originY + imgH)
        }
    }

    private func handleDragGesture(_ handle: Handle, viewScale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("boundingBox"))
            .onChanged { value in
                if activeHandle != handle {
                    activeHandle = handle
                    handleUndoSnapshot = PortraitUndoManager.snapshot(of: portrait)
                    dragStartScale = portrait.scale
                    dragStartOffsetX = portrait.offsetX
                    dragStartOffsetY = portrait.offsetY
                }

                let factor = CanvasConstants.editCanvas.width / max(1, canvasSide)
                let dxCanvas = Double(value.translation.width) * factor
                let dyCanvas = Double(value.translation.height) * factor

                let startW = cutoutSize.width * dragStartScale
                let startH = cutoutSize.height * dragStartScale

                // Anchor = center of the bounding box (scale from center)
                let centerX = dragStartOffsetX + startW / 2
                let centerY = dragStartOffsetY + startH / 2

                let draggedCornerX: Double
                let draggedCornerY: Double
                switch handle {
                case .topLeft:
                    draggedCornerX = dragStartOffsetX + dxCanvas
                    draggedCornerY = dragStartOffsetY + dyCanvas
                case .topRight:
                    draggedCornerX = dragStartOffsetX + startW + dxCanvas
                    draggedCornerY = dragStartOffsetY + dyCanvas
                case .bottomLeft:
                    draggedCornerX = dragStartOffsetX + dxCanvas
                    draggedCornerY = dragStartOffsetY + startH + dyCanvas
                case .bottomRight:
                    draggedCornerX = dragStartOffsetX + startW + dxCanvas
                    draggedCornerY = dragStartOffsetY + startH + dyCanvas
                }

                let newW = abs(draggedCornerX - centerX) * 2
                let newH = abs(draggedCornerY - centerY) * 2
                let scaleFromW = newW / cutoutSize.width
                let scaleFromH = newH / cutoutSize.height
                let rawScale = max(scaleFromW, scaleFromH)
                let newScale = min(max(rawScale, 0.05), 8.0)

                let w = cutoutSize.width * newScale
                let h = cutoutSize.height * newScale
                let newOffsetX = centerX - w / 2
                let newOffsetY = centerY - h / 2

                portrait.scale = newScale
                portrait.offsetX = newOffsetX
                portrait.offsetY = newOffsetY
                portrait.updatedAt = Date()
            }
            .onEnded { _ in
                activeHandle = nil
                onCommit()
                if let before = handleUndoSnapshot {
                    PortraitUndoManager.registerFromSnapshots(
                        before: before,
                        after: PortraitUndoManager.snapshot(of: portrait),
                        context: context,
                        undoManager: undoManager,
                        appState: appState,
                        actionName: Loc.scale
                    )
                    handleUndoSnapshot = nil
                }
            }
    }

}

// MARK: - Guide lines

/// Vertical + horizontal center guides shown during a drag.
/// Lines turn from gray-dashed to accent-colored solid when the image
/// snaps to the corresponding axis.
struct GuideLinesOverlay: View {
    let isVisible: Bool
    let snappedX: Bool
    let snappedY: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                // Vertical center line (snaps on X axis)
                line(from: CGPoint(x: w / 2, y: 0),
                     to:   CGPoint(x: w / 2, y: h),
                     active: snappedX)

                // Horizontal center line (snaps on Y axis)
                line(from: CGPoint(x: 0, y: h / 2),
                     to:   CGPoint(x: w, y: h / 2),
                     active: snappedY)
            }
            .opacity(isVisible ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: isVisible)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func line(from start: CGPoint, to end: CGPoint, active: Bool) -> some View {
        Path { p in
            p.move(to: start)
            p.addLine(to: end)
        }
        .stroke(
            active ? Color.accentColor : Color.white.opacity(0.7),
            style: StrokeStyle(
                lineWidth: active ? 1.5 : 1,
                lineCap: .round,
                dash: active ? [] : [4, 4]
            )
        )
        .shadow(color: .black.opacity(active ? 0.35 : 0.2), radius: 1)
    }
}

// MARK: - Alignment guide overlay

/// Semi-transparent "onion skin" overlay that draws two eye markers and a
/// head oval at the canonical alignment position.  Toggle it on to visually
/// verify that every portrait in the library shares the same eye height and
/// head size — especially useful after a bulk-align.
struct AlignmentGuideOverlay: View {
    let isVisible: Bool

    // Cyan guide colour — visible on both light and dark backgrounds.
    private let guideColor = Color(red: 0, green: 0.82, blue: 0.87)

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)

            // Target positions derived from the same constants the aligner uses.
            let ied    = CanvasConstants.targetInterEyeRatio * side
            let eyeCX  = CanvasConstants.targetEyeCenterX * side
            let eyeCY  = CanvasConstants.targetEyeCenterY * side
            let leftX  = eyeCX - ied / 2
            let rightX = eyeCX + ied / 2

            // Head oval — anthropometric proportions relative to inter-eye distance.
            let ovalW  = ied * 2.5
            let ovalH  = ied * 3.6
            // Eyes sit roughly 40% from the top of the skull, so the oval
            // centre is a bit below the eye line.
            let ovalCY = eyeCY + ovalH * 0.10

            ZStack {
                // ── Head oval ──────────────────────────────────
                Ellipse()
                    .stroke(guideColor.opacity(0.40),
                            style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .frame(width: ovalW, height: ovalH)
                    .position(x: eyeCX, y: ovalCY)

                // ── Horizontal eye line ────────────────────────
                Path { p in
                    p.move(to:    CGPoint(x: eyeCX - ovalW * 0.55, y: eyeCY))
                    p.addLine(to: CGPoint(x: eyeCX + ovalW * 0.55, y: eyeCY))
                }
                .stroke(guideColor.opacity(0.30),
                        style: StrokeStyle(lineWidth: 0.75, dash: [4, 3]))

                // ── Left eye ───────────────────────────────────
                eyeMarker(at: CGPoint(x: leftX, y: eyeCY), size: ied * 0.30)

                // ── Right eye ──────────────────────────────────
                eyeMarker(at: CGPoint(x: rightX, y: eyeCY), size: ied * 0.30)
            }
            .compositingGroup()
            .shadow(color: .black.opacity(0.25), radius: 1)
            .opacity(isVisible ? 1 : 0)
            .animation(.easeOut(duration: 0.15), value: isVisible)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func eyeMarker(at center: CGPoint, size: CGFloat) -> some View {
        ZStack {
            // Iris ring
            Circle()
                .stroke(guideColor.opacity(0.55), lineWidth: 1.5)
                .frame(width: size, height: size)
            // Pupil dot
            Circle()
                .fill(guideColor.opacity(0.45))
                .frame(width: size * 0.35, height: size * 0.35)
        }
        .position(center)
    }
}

// MARK: - Drop & processing overlays

/// Shown while the user is hovering a dragged image over the editor.
/// Subtle accent tint + dashed border + label so it's clear that releasing
/// here will start a new portrait.
private struct NewPhotoDropOverlay: View {
    var body: some View {
        ZStack {
            Color.accentColor.opacity(0.08)
            VStack(spacing: 14) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(.tint)
                Text(Loc.dropPhotoHere)
                    .font(.title3)
                    .foregroundStyle(.primary)
            }
            .padding(28)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.accentColor,
                              style: StrokeStyle(lineWidth: 2, dash: [10]))
                .padding(8)
        )
    }
}

/// Shown while ImportFlow is processing a freshly-dropped photo on the editor.
/// Uses the shared ProcessingStatusView so both the drop zone and the editor
/// cycle through the same playful status messages.
private struct ProcessingOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.05)
            ProcessingStatusView()
        }
    }
}

// MARK: - Advanced model hint

/// Small banner shown in the editor's controls panel when the advanced AI
/// model is not yet downloaded. Dismissible — stored in UserDefaults via
/// ModelManager.hintDismissed.
struct AdvancedModelHint: View {
    let modelManager: ModelManager
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
                .font(.caption)

            VStack(alignment: .leading, spacing: 4) {
                Text(Loc.betterHairAvailable)
                    .font(.caption.weight(.medium))
                Text(Loc.advancedModelHint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(Loc.openSettings) {
                    appState.selectedSettingsTab = .aiModel
                    openSettings()
                }
                .font(.caption2)
                .controlSize(.small)
            }

            Spacer(minLength: 0)

            Button {
                modelManager.hintDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(PressableButtonStyle())
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor.opacity(0.2), lineWidth: 0.5)
                )
        )
    }
}

// MARK: - Live preview canvas
//
// Built from native SwiftUI views (background layer + Image with scaleEffect/offset)
// rather than Canvas + Compositor. This is more reliable for live editing (no
// re-encode on every redraw) and lets gestures map 1:1 to view space.
// The Compositor is still used for PNG export.

struct CanvasPreview: View {
    let portrait: Portrait
    let background: BackgroundPreset?
    @Environment(AppState.self) private var appState

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            // Edit canvas is 1024pt; the visible side may differ. Scale all
            // stored canvas-space transforms to the visible side.
            let viewScale = side / CanvasConstants.editCanvas.width

            ZStack {
                backgroundView
                    .frame(width: side, height: side)

                if let cutout = appState.adjustedCutout(for: portrait) {
                    Image(decorative: cutout, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(
                            width: CGFloat(cutout.width) * portrait.scale * viewScale,
                            height: CGFloat(cutout.height) * portrait.scale * viewScale
                        )
                        .position(
                            x: (portrait.offsetX + Double(cutout.width) * portrait.scale / 2) * viewScale,
                            y: (portrait.offsetY + Double(cutout.height) * portrait.scale / 2) * viewScale
                        )
                } else {
                    ProgressView()
                }
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var backgroundView: some View {
        if let bg = background {
            switch bg.kind {
            case .image:
                if let img = appState.backgroundImage(for: bg) {
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .clipped()
                } else {
                    fallbackColor
                }
            case .color:
                let c = bg.colorComponents
                Color(.sRGB, red: c.0, green: c.1, blue: c.2, opacity: c.3)
            }
        } else {
            fallbackColor
        }
    }

    private var fallbackColor: some View {
        Color(.sRGB, red: 0.94, green: 0.95, blue: 0.97, opacity: 1.0)
    }
}

// MARK: - Background picker

struct BackgroundPicker: View {
    @Bindable var portrait: Portrait
    let backgrounds: [BackgroundPreset]
    @Environment(\.modelContext) private var context
    @Environment(\.undoManager) private var undoManager
    @Environment(AppState.self) private var appState
    @Query private var portraits: [Portrait]
    @State private var showAddPopover = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(backgrounds) { bg in
                    BackgroundChip(
                        preset: bg,
                        isSelected: portrait.backgroundPresetID == bg.id
                            || (portrait.backgroundPresetID == nil && bg.isDefault),
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

    // MARK: Actions

    private func select(_ bg: BackgroundPreset) {
        PortraitUndoManager.beginChange(for: portrait, context: context, undoManager: undoManager, appState: appState, actionName: Loc.backgroundAction)
        portrait.backgroundPresetID = bg.id
        portrait.updatedAt = Date()
        try? context.save()
    }

    private func setDefault(_ bg: BackgroundPreset) {
        for other in backgrounds { other.isDefault = false }
        bg.isDefault = true
        try? context.save()
    }

    private func delete(_ bg: BackgroundPreset) {
        // Clear the reference on EVERY portrait using this preset — otherwise
        // they'd keep pointing to a deleted model and the fallback lookup in
        // `selectedBackground` would silently pick the default (usually fine,
        // but cleaner to null them out explicitly).
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

// MARK: - Chip

struct BackgroundChip: View {
    let preset: BackgroundPreset
    let isSelected: Bool
    let onSelect: () -> Void
    let onSetDefault: () -> Void
    let onDelete: () -> Void

    @Environment(AppState.self) private var appState
    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var editName: String = ""
    @State private var isPressed = false
    @Environment(\.modelContext) private var context

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if preset.kind == .image, let img = appState.backgroundImage(for: preset) {
                        Image(img, scale: 1, label: Text(""))
                            .resizable()
                            .scaledToFill()
                    } else {
                        let c = preset.colorComponents
                        Color(.sRGB, red: c.0, green: c.1, blue: c.2, opacity: c.3)
                    }
                }
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.3),
                                      lineWidth: isSelected ? 2.5 : 1)
                        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isSelected)
                }
                .scaleEffect(isSelected ? 1.04 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isSelected)
                .shadow(color: .black.opacity(isSelected ? 0.18 : 0.06),
                        radius: isSelected ? 6 : 2, y: isSelected ? 3 : 1)
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .scaleEffect(isPressed ? 0.97 : 1.0)
                .animation(.easeOut(duration: 0.12), value: isPressed)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in if !isPressed { isPressed = true } }
                        .onEnded { _ in
                            isPressed = false
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                onSelect()
                            }
                        }
                )
                .contextMenu { menuContents }

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.white, Color.accentColor)
                        .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
                        .padding(4)
                        .symbolEffect(.bounce, value: isSelected)
                        .transition(.scale.combined(with: .opacity))
                }

                if isHovering && !isSelected {
                    Menu {
                        menuContents
                    } label: {
                        Image(systemName: "ellipsis.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.white, .black.opacity(0.55))
                            .shadow(radius: 1)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .padding(4)
                }
            }
            .onHover { isHovering = $0 }

            if isRenaming {
                TextField(Loc.name, text: $editName, onCommit: finishRename)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .font(.caption2)
                    .frame(width: 76)
            } else {
                Text(preset.name)
                    .font(.caption2)
                    .lineLimit(1)
            }
        }
        .frame(width: 80)
    }

    @ViewBuilder
    private var menuContents: some View {
        Button(Loc.select, action: onSelect)
        Button(Loc.rename) {
            editName = preset.name
            isRenaming = true
        }
        Button(preset.isDefault ? Loc.defaultCheck : Loc.setDefault, action: onSetDefault)
            .disabled(preset.isDefault)
        Divider()
        Button(Loc.delete, role: .destructive, action: onDelete)
            .disabled(preset.isDefault)
    }

    private func finishRename() {
        let trimmed = editName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            preset.name = trimmed
            try? context.save()
        }
        isRenaming = false
    }
}

// MARK: - Add button + popover

enum AddBackgroundKind {
    case image
    case color(Double, Double, Double)
}

struct AddBackgroundButton: View {
    @Binding var showPopover: Bool
    let onPick: (AddBackgroundKind) -> Void

    // Small curated palette. Kept neutral/on-brand — users can always upload custom.
    // Names are resolved at render time via Loc so they update on language change.
    private static let paletteColors: [(Double, Double, Double)] = [
        (1.00, 1.00, 1.00),
        (0.93, 0.95, 0.97),
        (0.96, 0.94, 0.91),
        (0.83, 0.89, 0.95),
        (0.85, 0.92, 0.86),
        (0.97, 0.89, 0.84),
        (0.15, 0.25, 0.45),
        (0.18, 0.19, 0.22),
    ]
    private static var paletteNames: [String] {
        [Loc.white, Loc.lightGray, Loc.warmWhite, Loc.softBlue,
         Loc.softGreen, Loc.peach, Loc.deepBlue, Loc.anthracite]
    }
    private var palette: [(String, Double, Double, Double)] {
        zip(Self.paletteNames, Self.paletteColors).map { ($0, $1.0, $1.1, $1.2) }
    }

    var body: some View {
        VStack(spacing: 4) {
            Button {
                showPopover.toggle()
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(.controlBackgroundColor))
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            Color.secondary.opacity(0.4),
                            style: StrokeStyle(lineWidth: 1, dash: [3])
                        )
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 72, height: 72)
            }
            .buttonStyle(PressableButtonStyle())
            .popover(isPresented: $showPopover, arrowEdge: .top) {
                popoverContents
            }

            Text(Loc.add)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 80)
    }

    private var popoverContents: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                showPopover = false
                onPick(.image)
            } label: {
                Label(Loc.uploadImage, systemImage: "photo.badge.plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())

            Divider()

            Text(Loc.chooseColor)
                .font(.caption)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 8), count: 4),
                      spacing: 8) {
                ForEach(palette, id: \.0) { item in
                    Button {
                        showPopover = false
                        onPick(.color(item.1, item.2, item.3))
                    } label: {
                        Circle()
                            .fill(Color(.sRGB, red: item.1, green: item.2, blue: item.3, opacity: 1))
                            .frame(width: 30, height: 30)
                            .overlay {
                                Circle().strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
                            }
                    }
                    .buttonStyle(PressableButtonStyle())
                    .help(item.0)
                }
            }
        }
        .padding(14)
        .frame(width: 240)
    }
}

private struct UpscaleInstallPopover: View {
    let manager: UpscaleModelManager
    let onRequestUpscale: () -> Void
    let onDismiss: () -> Void

    @State private var variant: UpscaleModelManager.Variant

    init(manager: UpscaleModelManager,
         onRequestUpscale: @escaping () -> Void,
         onDismiss: @escaping () -> Void) {
        self.manager = manager
        self.onRequestUpscale = onRequestUpscale
        self.onDismiss = onDismiss
        self._variant = State(initialValue: manager.selectedVariant)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Loc.upscalePopoverTitle).font(.headline)
                Text(Loc.upscalePopoverBlurb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker("", selection: $variant) {
                Text(Loc.upscaleVariant2x).tag(UpscaleModelManager.Variant.x2)
                Text(Loc.upscaleVariant4x).tag(UpscaleModelManager.Variant.x4)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: variant) { _, new in
                manager.selectedVariant = new
            }
            statusBlock
        }
        .padding(16)
        .frame(width: 300)
        .onDisappear { onDismiss() }
    }

    @ViewBuilder
    private var statusBlock: some View {
        switch manager.status(for: variant) {
        case .notInstalled:
            VStack(alignment: .leading, spacing: 8) {
                Text(Loc.upscaleApproxSize)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Button {
                    manager.selectedVariant = variant
                    manager.downloadAndInstall(variant)
                    onRequestUpscale()
                } label: {
                    Label(Loc.installAndUpscale, systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }

        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(Loc.downloading).foregroundStyle(.secondary).font(.caption)
                    Spacer()
                    Text("\(Int(progress * 100))%")
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                ProgressView(value: progress)
                HStack {
                    Spacer()
                    Button(Loc.cancel) { manager.cancelDownload(variant) }
                        .controlSize(.small)
                }
            }

        case .ready:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(Loc.modelAvailable)
                }
                Button {
                    manager.selectedVariant = variant
                    onRequestUpscale()
                } label: {
                    Label(Loc.upscaleNow, systemImage: "arrow.up.left.and.arrow.down.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

        case .error(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(Loc.error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button(Loc.retry) {
                        manager.downloadAndInstall(variant)
                        onRequestUpscale()
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}
