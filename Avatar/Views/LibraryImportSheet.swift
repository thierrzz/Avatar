import SwiftUI
import SwiftData

struct LibraryImportSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var preview: ImportPreview?
    @State private var strategy: ImportConflictStrategy = .skip
    @State private var isImporting = false
    @State private var progress: Double = 0
    @State private var result: ImportResult?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(Loc.importLibraryTitle).font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            if let errorMessage {
                errorView(errorMessage)
            } else if let result {
                resultView(result)
            } else if let preview {
                previewView(preview)
            } else {
                ProgressView()
                    .padding(40)
            }

            Divider()

            // Actions
            HStack {
                Spacer()
                if result != nil {
                    Button(Loc.close) { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else if isImporting {
                    ProgressView(value: progress)
                        .frame(width: 120)
                    Text(Loc.importing)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button(Loc.cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    if preview != nil {
                        Button(Loc.importButton) { startImport() }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .padding()
        }
        .frame(width: 420, height: result != nil ? 280 : 360)
        .task { loadPreview() }
    }

    // MARK: - Subviews

    @ViewBuilder
    private func previewView(_ preview: ImportPreview) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Summary
            VStack(alignment: .leading, spacing: 6) {
                Label(Loc.portraitsCount(preview.portraitCount), systemImage: "person.crop.rectangle.stack")
                Label(Loc.backgroundsCount(preview.backgroundCount), systemImage: "photo")
                Label(Loc.presetsCount(preview.presetCount), systemImage: "rectangle.3.group")
            }
            .font(.body)

            // Conflicts
            if preview.hasConflicts {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Label(Loc.conflictsFound, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.subheadline.weight(.medium))

                    let totalConflicts = preview.conflictingPortraitIDs.count + preview.conflictingBackgroundIDs.count
                    Text(Loc.conflictMessage(totalConflicts))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("", selection: $strategy) {
                        ForEach(ImportConflictStrategy.allCases) { s in
                            Text(s.label).tag(s)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func resultView(_ result: ImportResult) -> some View {
        VStack(spacing: 12) {
            Image(systemName: result.errors.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(result.errors.isEmpty ? .green : .orange)

            Text(Loc.importComplete)
                .font(.headline)

            let total = result.portraitsImported + result.backgroundsImported + result.presetsImported
            Text(Loc.importResult(total, result.skipped))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if !result.errors.isEmpty {
                Text(Loc.importErrors(result.errors.count))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.red)
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func loadPreview() {
        do {
            preview = try LibraryImporter.preview(url: url, context: context)
        } catch let err as LibraryImporterError {
            errorMessage = err.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startImport() {
        isImporting = true
        Task {
            do {
                result = try await LibraryImporter.importLibrary(
                    url: url,
                    strategy: strategy,
                    context: context,
                    progress: { self.progress = $0 }
                )
            } catch {
                errorMessage = error.localizedDescription
            }
            isImporting = false
        }
    }
}
