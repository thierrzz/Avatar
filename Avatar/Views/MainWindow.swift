import SwiftUI
import SwiftData

struct MainWindow: View {
    @Environment(AppState.self) private var appState
    @Environment(ModelManager.self) private var modelManager
    @Environment(\.modelContext) private var context
    @Query(sort: \Portrait.updatedAt, order: .reverse) private var portraits: [Portrait]
    var body: some View {
        @Bindable var state = appState
        NavigationSplitView {
            LibraryView(selection: $state.selectedPortraitID)
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 360)
        } detail: {
            if let id = state.selectedPortraitID,
               let portrait = portraits.first(where: { $0.id == id }) {
                EditorView(portrait: portrait)
            } else {
                ImportDropZone()
            }
        }
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    pickFile()
                } label: {
                    Label(Loc.importPhoto, systemImage: "plus")
                }
                .help(Loc.importPhotoHelp)
            }
        }
        .sheet(isPresented: $state.showProUpgradeSheet) {
            ProUpgradeSheet()
                .environment(appState)
        }
        .onOpenURL { url in
            URLSchemeHandler.handle(url, appState: appState)
        }
        .task {
            // Refresh Pro entitlement on launch so the badge/credits are accurate.
            appState.refreshEntitlement()
        }
    }

    private func pickFile() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            ImportFlow.importFile(url: url, context: context, appState: appState,
                                         modelManager: modelManager)
        }
        #endif
    }
}
