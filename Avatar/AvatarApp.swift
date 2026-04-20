import SwiftUI
import SwiftData
import UniformTypeIdentifiers

@main
struct AvatarApp: App {
    @State private var appState = AppState()
    @State private var updater = UpdateManager()
    @State private var modelManager = ModelManager()
    @State private var googleAuth: GoogleAuthService
    @State private var syncEngine: SyncEngine
    @State private var showExportSheet = false

    init() {
        let auth = GoogleAuthService()
        _googleAuth = State(initialValue: auth)
        _syncEngine = State(initialValue: SyncEngine(authService: auth))
    }

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
                .environment(syncEngine)
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
                        return
                    }
                    if let join = PendingJoin(url: url) {
                        handleJoin(join)
                    }
                }
                .onChange(of: googleAuth.isSignedIn) { _, signedIn in
                    if signedIn, let join = appState.pendingJoin {
                        appState.pendingJoin = nil
                        runJoin(join)
                    }
                }
                .alert(
                    Loc.wrongAccountTitle,
                    isPresented: Binding(
                        get: { appState.wrongAccountInvite != nil },
                        set: { if !$0 { appState.wrongAccountInvite = nil } }
                    ),
                    presenting: appState.wrongAccountInvite
                ) { info in
                    Button(Loc.switchAccount) {
                        appState.pendingJoin = info.join
                        appState.wrongAccountInvite = nil
                        googleAuth.signOut()
                        googleAuth.signIn()
                    }
                    Button(Loc.dismiss, role: .cancel) {
                        appState.wrongAccountInvite = nil
                    }
                } message: { info in
                    Text(Loc.wrongAccountMessage(invited: info.invited, actual: info.actual))
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

    private func handleJoin(_ join: PendingJoin) {
        if googleAuth.isSignedIn {
            runJoin(join)
        } else {
            appState.pendingJoin = join
        }
    }

    private func runJoin(_ join: PendingJoin) {
        if let invited = join.invitedEmail,
           let actual = googleAuth.userEmail,
           invited.caseInsensitiveCompare(actual) != .orderedSame {
            appState.wrongAccountInvite = WrongAccountInvite(
                invited: invited,
                actual: actual,
                join: join
            )
            return
        }

        let context = sharedModelContainer.mainContext
        Task { @MainActor in
            do {
                let workspace = try await syncEngine.joinWorkspace(
                    folderID: join.folderID,
                    folderName: join.name,
                    context: context
                )
                appState.selectedWorkspaceID = workspace.id
                appState.selectedPortraitIDs.removeAll()
            } catch {
                appState.lastError = error.localizedDescription
            }
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
