import SwiftUI
import SwiftData

@main
struct AvatarApp: App {
    @State private var appState = AppState()
    @State private var updater = UpdateManager()
    @State private var modelManager = ModelManager()
    @State private var upscaleManager = UpscaleModelManager()

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Portrait.self,
            BackgroundPreset.self,
            ExportPreset.self,
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
                .environment(upscaleManager)
                // Minimum ensures the library sidebar (~200), canvas (~280)
                // and inspector (~320) all have enough room to display
                // their content without truncation.
                .frame(minWidth: 860, minHeight: 520)
                .id(appState.language)
                .task {
                    SeedData.seedIfNeeded(context: sharedModelContainer.mainContext)
                    updater.checkForUpdatesInBackground()
                }
        }
        .modelContainer(sharedModelContainer)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }

        Settings {
            SettingsView()
                .environment(appState)
                .environment(updater)
                .environment(modelManager)
                .environment(upscaleManager)
                .modelContainer(sharedModelContainer)
                .id(appState.language)
        }
    }
}
