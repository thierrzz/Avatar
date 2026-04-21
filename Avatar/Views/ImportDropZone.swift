import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ImportDropZone: View {
    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var appState
    @Environment(ModelManager.self) private var modelManager
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.tint)
            Text(Loc.dropHere)
                .font(.title2)
            Text(Loc.orUseButton)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                .foregroundStyle(hovering ? Color.accentColor : Color.secondary.opacity(0.4))
                .animation(.easeOut(duration: 0.15), value: hovering)
                .padding(40)
        )
        .onDrop(of: [.fileURL, .image], isTargeted: $hovering) { providers in
            PortraitDropHandler.handle(providers: providers, context: context, appState: appState,
                                           modelManager: modelManager)
        }
        .overlay {
            if appState.isProcessing {
                ProcessingStatusView()
            }
            if let err = appState.lastError {
                VStack {
                    Spacer()
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .padding(10)
                        .background(.red.opacity(0.85))
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                        .padding(.bottom, 24)
                }
            }
        }
    }

}
