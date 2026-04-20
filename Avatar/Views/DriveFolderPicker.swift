import SwiftUI

/// A simple model representing a Google Drive folder for the picker.
struct DriveFolder: Identifiable, Hashable {
    let id: String
    let name: String
}

/// A sheet that lets the user browse their Google Drive folders
/// and pick a location for the workspace.
struct DriveFolderPicker: View {
    let authService: GoogleAuthService
    let onSelect: (DriveFolder?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var folders: [DriveFolder] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var navigationPath: [DriveFolder] = []

    /// The folder we're currently looking inside.
    private var currentFolderID: String {
        navigationPath.last?.id ?? "root"
    }

    private var currentFolderName: String {
        navigationPath.last?.name ?? Loc.myDrive
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(Loc.chooseDriveFolder)
                        .font(.headline)
                    Spacer()
                    Button(Loc.cancel) { dismiss() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                Text(Loc.chooseFolderSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            // Breadcrumb navigation
            HStack(spacing: 4) {
                Button(Loc.myDrive) {
                    navigationPath.removeAll()
                    loadFolders()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: navigationPath.isEmpty ? .semibold : .regular))
                .foregroundStyle(navigationPath.isEmpty ? .primary : Color.accentColor)

                ForEach(Array(navigationPath.enumerated()), id: \.element.id) { index, folder in
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)

                    Button(folder.name) {
                        navigationPath = Array(navigationPath.prefix(index + 1))
                        loadFolders()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: index == navigationPath.count - 1 ? .semibold : .regular))
                    .foregroundStyle(index == navigationPath.count - 1 ? .primary : Color.accentColor)
                    .lineLimit(1)
                }

                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(.controlBackgroundColor))

            Divider()

            // Folder list
            if isLoading {
                VStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if let error {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button(Loc.tryAgain) { loadFolders() }
                        .font(.caption)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding()
            } else if folders.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "folder")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(Loc.noFoldersFound)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(folders) { folder in
                        HStack(spacing: 8) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.blue)

                            Text(folder.name)
                                .font(.system(size: 13))
                                .lineLimit(1)

                            Spacer()

                            // Navigate into subfolder
                            Button {
                                navigationPath.append(folder)
                                loadFolders()
                            } label: {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            // Double-click navigates into the folder
                            navigationPath.append(folder)
                            loadFolders()
                        }
                    }
                }
                .listStyle(.plain)
            }

            Divider()

            // Footer with select button
            HStack {
                Image(systemName: "folder.fill")
                    .font(.caption)
                    .foregroundStyle(.blue)
                Text(currentFolderName)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                Button(Loc.cancel) {
                    dismiss()
                }

                Button(Loc.selectFolder) {
                    if let last = navigationPath.last {
                        onSelect(last)
                    } else {
                        onSelect(nil) // root = My Drive
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 420, height: 400)
        .task {
            loadFolders()
        }
    }

    private func loadFolders() {
        isLoading = true
        error = nil

        Task {
            do {
                let driveService = DriveService(authService: authService)
                let driveFiles = try await driveService.listFolders(inParent: currentFolderID)
                folders = driveFiles.map { DriveFolder(id: $0.id, name: $0.name) }
            } catch {
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }
}
