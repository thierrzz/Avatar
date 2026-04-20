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
            VStack(spacing: 0) {
                WorkspaceSwitcher()

                Divider()

                LibraryView(selection: $state.selectedPortraitIDs)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 360)
        } detail: {
            if state.isBatchSelected {
                BatchEditorView()
            } else if let id = state.selectedPortraitID,
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
    }

    private func pickFile() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            let urls = panel.urls
            if urls.count == 1, let url = urls.first {
                ImportFlow.importFile(url: url, context: context, appState: appState,
                                             modelManager: modelManager)
            } else if urls.count > 1 {
                ImportFlow.importFiles(urls: urls, context: context, appState: appState,
                                              modelManager: modelManager)
            }
        }
        #endif
    }
}
