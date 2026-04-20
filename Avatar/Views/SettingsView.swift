import SwiftUI
import SwiftData
import AppKit
import Sparkle

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        TabView(selection: $appState.selectedSettingsTab) {
            BackgroundsSettings()
                .tabItem { Label(Loc.backgrounds, systemImage: "photo.on.rectangle") }
                .tag(SettingsTab.backgrounds)
            ExportPresetsSettings()
                .tabItem { Label(Loc.exportPresets, systemImage: "square.and.arrow.up.on.square") }
                .tag(SettingsTab.exportPresets)
            AIModelSettings()
                .tabItem { Label("AI Model", systemImage: "brain") }
                .tag(SettingsTab.aiModel)
            UpdatesSettings()
                .tabItem { Label(Loc.updates, systemImage: "arrow.triangle.2.circlepath") }
                .tag(SettingsTab.updates)
            LanguageSettings()
                .tabItem { Label(Loc.language, systemImage: "globe") }
                .tag(SettingsTab.language)
        }
        .frame(width: 640, height: 460)
        .padding()
    }
}

// MARK: - Backgrounds

struct BackgroundsSettings: View {
    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var appState
    @Query(sort: \BackgroundPreset.createdAt) private var backgrounds: [BackgroundPreset]
    @State private var newColor = Color(.sRGB, red: 0.93, green: 0.95, blue: 0.97, opacity: 1.0)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(Loc.backgrounds).font(.headline)
                Spacer()
                Button {
                    addImage()
                } label: { Label(Loc.addImage, systemImage: "photo.badge.plus") }
                ColorPicker("", selection: $newColor, supportsOpacity: false)
                    .labelsHidden()
                Button(Loc.addColor) { addColor() }
            }

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], spacing: 12) {
                    ForEach(backgrounds) { bg in
                        BackgroundSettingsCard(preset: bg)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func addImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) {
            let name = url.deletingPathExtension().lastPathComponent
            let bg = BackgroundPreset(name: name, kind: .image, imageData: data)
            context.insert(bg)
            try? context.save()
        }
    }

    private func addColor() {
        let ns = NSColor(newColor).usingColorSpace(.sRGB) ?? .white
        let bg = BackgroundPreset(
            name: Loc.color,
            kind: .color,
            color: (Double(ns.redComponent), Double(ns.greenComponent),
                    Double(ns.blueComponent), Double(ns.alphaComponent))
        )
        context.insert(bg)
        try? context.save()
    }
}

private struct BackgroundSettingsCard: View {
    @Bindable var preset: BackgroundPreset
    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var appState
    @Query private var allBackgrounds: [BackgroundPreset]

    var body: some View {
        VStack(spacing: 6) {
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
            .frame(height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(preset.isDefault ? Color.accentColor : Color.secondary.opacity(0.3),
                                  lineWidth: preset.isDefault ? 2 : 1)
            }

            TextField(Loc.name, text: $preset.name)
                .textFieldStyle(.plain)
                .font(.caption)
                .multilineTextAlignment(.center)
                .onChange(of: preset.name) { _, _ in try? context.save() }

            HStack(spacing: 6) {
                Button {
                    setDefault()
                } label: {
                    Image(systemName: preset.isDefault ? "star.fill" : "star")
                }
                .buttonStyle(.plain)
                .help(Loc.setAsDefault)

                Button {
                    context.delete(preset)
                    try? context.save()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .disabled(preset.isDefault)
            }
            .font(.caption)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.controlBackgroundColor))
        )
    }

    private func setDefault() {
        for bg in allBackgrounds { bg.isDefault = false }
        preset.isDefault = true
        try? context.save()
    }
}

// MARK: - Export presets

struct ExportPresetsSettings: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ExportPreset.sortOrder) private var presets: [ExportPreset]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(Loc.exportPresets).font(.headline)
                Spacer()
                Button {
                    let next = (presets.map(\.sortOrder).max() ?? 0) + 1
                    let p = ExportPreset(name: Loc.new, width: 512, height: 512,
                                         shape: .square, isBuiltIn: false, sortOrder: next)
                    context.insert(p)
                    try? context.save()
                } label: { Label(Loc.addPreset, systemImage: "plus") }
            }

            Table(presets) {
                TableColumn(Loc.name) { p in
                    TextField("", text: Binding(get: { p.name }, set: { p.name = $0; try? context.save() }))
                }
                TableColumn(Loc.width) { p in
                    TextField("", value: Binding(
                        get: { p.width },
                        set: { p.width = max(16, $0); try? context.save() }
                    ), format: .number)
                }
                TableColumn(Loc.height) { p in
                    TextField("", value: Binding(
                        get: { p.height },
                        set: { p.height = max(16, $0); try? context.save() }
                    ), format: .number)
                }
                TableColumn(Loc.shape) { p in
                    Picker("", selection: Binding(
                        get: { p.shape },
                        set: { p.shape = $0; try? context.save() }
                    )) {
                        ForEach(ExportShape.allCases) { s in Text(s.label).tag(s) }
                    }
                    .labelsHidden()
                }
                TableColumn("") { p in
                    Button {
                        context.delete(p)
                        try? context.save()
                    } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain)
                    .disabled(p.isBuiltIn)
                }
                .width(28)
            }
        }
    }
}

// MARK: - AI Model (Hair Quality)

struct AIModelSettings: View {
    @Environment(ModelManager.self) private var modelManager
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                birefnetSection
                Divider()
                proSection
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Pro / Extend Body section

    @ViewBuilder
    private var proSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Loc.proSectionTitle).font(.headline)

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "person.crop.rectangle.badge.plus")
                            .font(.title2)
                            .foregroundStyle(.tint)
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(Loc.extendBody).font(.body.weight(.medium))
                            Text(Loc.extendBodyHelp)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Divider()

                    if !appState.auth.isSignedIn {
                        Button {
                            appState.auth.startSignIn()
                        } label: {
                            Label(Loc.proSignInWithGoogle, systemImage: "person.crop.circle.badge.checkmark")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    } else {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                if let email = appState.auth.email {
                                    Text(email).font(.caption).foregroundStyle(.secondary)
                                }
                                if let tier = appState.proEntitlement.tier {
                                    HStack(spacing: 6) {
                                        Text(Loc.proCurrentPlan + ":")
                                        Text(tier.displayName).fontWeight(.medium)
                                    }
                                    Text("\(Loc.proCreditsRemaining): \(appState.proEntitlement.credits)")
                                    if let renews = appState.proEntitlement.renewsAt {
                                        Text("\(Loc.proRenewsAt): \(renews.formatted(date: .abbreviated, time: .omitted))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                } else {
                                    Text(Loc.proNoSubscription)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 6) {
                                if appState.proEntitlement.isPro {
                                    Button(Loc.proManageSubscription) {
                                        Task { await openPortal() }
                                    }
                                    .controlSize(.small)
                                } else {
                                    Button(Loc.proUpgradeNow) {
                                        appState.showProUpgradeSheet = true
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                }
                                Button(Loc.proSignOut) {
                                    appState.auth.signOut()
                                    appState.proEntitlement.clear()
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
                .padding(4)
            }
        }
    }

    @MainActor
    private func openPortal() async {
        do {
            let url = try await appState.backend.openPortal()
            NSWorkspace.shared.open(url)
        } catch {
            appState.lastError = (error as? LocalizedError)?.errorDescription
        }
    }

    // MARK: - Existing BiRefNet section (renamed from `body`)

    @ViewBuilder
    private var birefnetSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(Loc.aiHairQuality).font(.headline)

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "wand.and.stars.inverse")
                            .font(.title2)
                            .foregroundStyle(.tint)
                            .frame(width: 32)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(Loc.advancedCutoutModel)
                                .font(.body.weight(.medium))
                            Text(Loc.advancedModelDesc)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Divider()

                    switch modelManager.status {
                    case .notInstalled:
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 4) {
                                Image(systemName: "circle.dashed")
                                    .foregroundStyle(.secondary)
                                Text(Loc.modelNotInstalled)
                                    .foregroundStyle(.secondary)
                            }

                            Text(Loc.downloadModelPrompt)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)

                            Button(Loc.installModel) {
                                modelManager.downloadAndInstall()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }

                    case .downloading(let progress):
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(Loc.downloading)
                                    .foregroundStyle(.secondary)
                            }

                            ProgressView(value: progress)

                            HStack {
                                Text("\(Int(progress * 100))%")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                Spacer()
                                Button(Loc.cancel) {
                                    modelManager.cancelDownload()
                                }
                                .controlSize(.small)
                            }
                        }

                    case .ready:
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                    Text(Loc.modelAvailable)
                                }
                                if let size = modelManager.installedSize {
                                    Text(Loc.sizeOnDisk(size))
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                            Button(Loc.delete, role: .destructive) {
                                modelManager.deleteModel()
                            }
                            .controlSize(.small)
                        }

                        Divider()

                        Toggle(Loc.useAdvancedModel,
                               isOn: Binding(
                                get: { modelManager.useAdvancedModel },
                                set: { modelManager.useAdvancedModel = $0 }
                               ))
                        Text(Loc.advancedModelToggleHelp)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)

                    case .error(let message):
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Label(Loc.error, systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(Loc.retry) {
                                modelManager.downloadAndInstall()
                            }
                            .controlSize(.small)
                        }
                    }
                }
                .padding(4)
            }

            Spacer()
        }
    }
}

// MARK: - Updates

struct UpdatesSettings: View {
    @Environment(UpdateManager.self) private var updater

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "–"
    }

    var body: some View {
        @Bindable var updater = updater

        VStack(alignment: .leading, spacing: 16) {
            Text(Loc.updates).font(.headline)

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(Loc.currentVersion)
                        Spacer()
                        Text("\(appVersion) (\(buildNumber))")
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    Toggle(Loc.autoCheckUpdates,
                           isOn: Binding(
                            get: { updater.automaticallyChecksForUpdates },
                            set: { updater.automaticallyChecksForUpdates = $0 }
                           ))

                    Divider()

                    HStack {
                        Button(Loc.checkNow) {
                            updater.checkForUpdates()
                        }
                        .disabled(!updater.canCheckForUpdates)

                        Spacer()

                        if let date = updater.lastUpdateCheckDate {
                            Text(Loc.lastChecked(date.formatted(.relative(presentation: .named))))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if case .readyToRelaunch(let version) = updater.state {
                        Divider()
                        HStack {
                            Label(Loc.versionReady(version),
                                  systemImage: "arrow.triangle.2.circlepath.circle.fill")
                            .foregroundStyle(.tint)
                            Spacer()
                            Button(Loc.relaunch) {
                                updater.relaunchAndInstall()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                }
                .padding(4)
            }

            Spacer()
        }
    }
}

// MARK: - Language

struct LanguageSettings: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(Loc.language).font(.headline)

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text(Loc.languageDesc)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker(Loc.language, selection: Binding(
                        get: { appState.language },
                        set: { appState.language = $0 }
                    )) {
                        ForEach(Lang.allCases) { lang in
                            Text(lang.label).tag(lang)
                        }
                    }
                    .pickerStyle(.radioGroup)
                }
                .padding(4)
            }

            Spacer()
        }
    }
}
