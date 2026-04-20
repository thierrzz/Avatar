import SwiftUI
import SwiftData
import UniformTypeIdentifiers

@main
struct AvatarApp: App {
    @State private var appState = AppState()
    @State private var updater = UpdateManager()
    @State private var modelManager = ModelManager()
    @State private var googleAuth = GoogleAuthService()
    @State private var showExportSheet = false

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Portrait.self,
            BackgroundPreset.self,
            ExportPreset.self,
            Workspace.self,
            SyncState.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            MainWindow()
                .environment(appState)
                .environment(updater)
                .environment(modelManager)
                .environment(googleAuth)
                .environment(SyncEngine(authService: googleAuth))
                // Minimum ensures the library sidebar (~200), canvas (~280)
                // and inspector (~320) all have enough room to display
                // their content without truncation.
                .frame(minWidth: 860, minHeight: 520)
                .id(appState.language)
                .task {
                    SeedData.seedIfNeeded(context: sharedModelContainer.mainContext)
                    updater.checkForUpdatesInBackground()
                    googleAuth.restorePreviousSignIn()
                }
                .sheet(isPresented: $showExportSheet) {
                    LibraryExportSheet()
                }
                .sheet(item: Binding(
                    get: { appState.libraryImportURL },
                    set: { appState.libraryImportURL = $0 }
                )) { url in
                    LibraryImportSheet(url: url)
                }
                .onOpenURL { url in
                    if url.pathExtension.lowercased() == "avatarlib" {
                        appState.libraryImportURL = url
                    }
                }
        }
        .modelContainer(sharedModelContainer)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .newItem) {
                Button(Loc.exportLibrary) {
                    showExportSheet = true
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Button(Loc.importLibrary) {
                    pickLibraryFile()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environment(appState)
                .environment(updater)
                .environment(modelManager)
                .modelContainer(sharedModelContainer)
                .id(appState.language)
        }
    }

    private func pickLibraryFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.avatarLibrary]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            appState.libraryImportURL = url
        }
    }
}

// MARK: - URL + Identifiable (for .sheet(item:))
extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
