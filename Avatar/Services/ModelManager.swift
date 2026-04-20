import Foundation
import CoreML

/// Manages the optional BiRefNet CoreML model for high-quality hair matting.
///
/// The model is NOT bundled with the app. Users install it via the
/// "AI Model" settings tab which downloads a pre-compiled `.mlmodelc`
/// archive from a hosted URL and extracts it into
/// `~/Library/Application Support/Avatar/Models/`.
///
/// Usage: inject as `@Environment(ModelManager.self)` and call
/// `modelManager.isAvailable` to decide which segmentation pipeline to use.
@MainActor
@Observable
final class ModelManager {

    // MARK: - Public state

    enum Status: Equatable {
        case notInstalled
        case downloading(progress: Double)   // 0.0–1.0
        case ready
        case error(String)
    }

    private(set) var status: Status = .notInstalled

    /// Quick check — avoids loading the model from disk every time.
    var isAvailable: Bool { status == .ready }

    /// Whether we're currently downloading.
    var isDownloading: Bool {
        if case .downloading = status { return true }
        return false
    }

    /// User preference: even when installed, user can opt out.
    /// Stored as UserDefaults so it persists across launches.
    var useAdvancedModel: Bool {
        get { UserDefaults.standard.bool(forKey: Self.prefKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.prefKey) }
    }

    /// Whether the user dismissed the editor hint banner.
    var hintDismissed: Bool {
        get { UserDefaults.standard.bool(forKey: Self.hintDismissedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.hintDismissedKey) }
    }

    // MARK: - Model access

    /// Returns the cached compiled CoreML model if it has already been loaded
    /// into memory. Never performs a synchronous load — first-time loads must
    /// go through `loadModelAsync()` to keep the main thread responsive (the
    /// Neural Engine program compile on `MLModel.init` can block for several
    /// seconds on first use and would otherwise freeze the UI mid-drop).
    func loadModel() -> MLModel? {
        guard status == .ready else { return nil }
        return cachedModel
    }

    /// Loads the compiled CoreML model, performing the heavy
    /// `MLModel(contentsOf:configuration:)` call on a background executor so
    /// the main thread stays responsive. Safe to call repeatedly — subsequent
    /// calls return the cached instance.
    func loadModelAsync() async -> MLModel? {
        guard status == .ready else { return nil }
        if let cached = cachedModel { return cached }

        let compiledURL = Self.modelsDirectory.appendingPathComponent(Self.compiledModelName)
        guard FileManager.default.fileExists(atPath: compiledURL.path) else {
            status = .notInstalled
            return nil
        }

        do {
            let model = try await Self.loadCompiled(at: compiledURL)
            cachedModel = model
            return model
        } catch {
            print("[ModelManager] Failed to load model: \(error)")
            status = .error(Loc.modelLoadFailed(error.localizedDescription))
            return nil
        }
    }

    /// Background-thread model loader. Isolated to a detached task so the
    /// Neural Engine compile step does not stall the main actor.
    nonisolated private static func loadCompiled(at url: URL) async throws -> MLModel {
        try await Task.detached(priority: .userInitiated) {
            let config = MLModelConfiguration()
            config.computeUnits = .all
            return try MLModel(contentsOf: url, configuration: config)
        }.value
    }

    /// Starts a background load of the compiled model if one isn't already in
    /// memory. Called on launch / after install so the first drop doesn't pay
    /// the multi-second Neural Engine compile cost on the main thread.
    func warmUp() {
        guard status == .ready, cachedModel == nil else { return }
        Task { [weak self] in
            _ = await self?.loadModelAsync()
            print("[ModelManager] warm-up complete")
        }
    }

    // MARK: - Download & Install

    /// Downloads the pre-compiled BiRefNet model from the hosted URL,
    /// extracts it, and installs it into the models directory.
    func downloadAndInstall() {
        guard !isDownloading else { return }

        // Check if the model is already on disk (e.g. installed by the
        // conversion script or a previous session). Skip the download only
        // when the on-disk version matches what the app currently expects;
        // otherwise we re-download to pick up fixes.
        let existing = Self.modelsDirectory.appendingPathComponent(Self.compiledModelName)
        if FileManager.default.fileExists(atPath: existing.path),
           installedModelVersion == Self.currentModelVersion {
            status = .ready
            if !UserDefaults.standard.bool(forKey: Self.prefKey) {
                useAdvancedModel = true
            }
            warmUp()
            print("[ModelManager] Model already on disk, skipping download")
            return
        }

        status = .downloading(progress: 0)

        let delegate = DownloadDelegate()
        delegate.onProgress = { [weak self] progress in
            Task { @MainActor in
                self?.status = .downloading(progress: progress)
            }
        }
        delegate.onComplete = { [weak self] tempURL, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    if (error as NSError).code == NSURLErrorCancelled {
                        self.status = .notInstalled
                    } else {
                        self.status = .error(Loc.downloadFailed(error.localizedDescription))
                    }
                    return
                }
                guard let tempURL else {
                    self.status = .error(Loc.downloadNoFile)
                    return
                }
                do {
                    try self.extractAndInstall(from: tempURL)
                    try? FileManager.default.removeItem(at: tempURL)
                    self.status = .ready
                    self.useAdvancedModel = true
                    print("[ModelManager] Model downloaded and installed successfully")
                } catch {
                    try? FileManager.default.removeItem(at: tempURL)
                    self.status = .error(Loc.installFailed(error.localizedDescription))
                    print("[ModelManager] Install failed: \(error)")
                }
            }
        }
        self.downloadDelegate = delegate

        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: Self.modelDownloadURL)
        downloadTask = task
        task.resume()
        print("[ModelManager] Download started from: \(Self.modelDownloadURL)")
    }

    /// Cancels an in-progress download.
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadDelegate = nil
        status = .notInstalled
        print("[ModelManager] Download cancelled")
    }

    // MARK: - Refresh / check

    /// Re-scans the models directory for the compiled model. If an older
    /// version of the model is found on disk (mismatching `currentModelVersion`),
    /// it is removed so the app can re-download the corrected build — users
    /// who installed the v1 model had a cutout with missing ImageNet
    /// normalization and need the v2 asset.
    func refresh() {
        cachedModel = nil
        let file = Self.modelsDirectory.appendingPathComponent(Self.compiledModelName)
        if FileManager.default.fileExists(atPath: file.path) {
            if installedModelVersion != Self.currentModelVersion {
                print("[ModelManager] Installed model version '\(installedModelVersion ?? "unknown")' " +
                      "does not match expected '\(Self.currentModelVersion)' — removing for re-download")
                try? FileManager.default.removeItem(at: file)
                try? FileManager.default.removeItem(at: Self.versionSidecarURL)
                status = .notInstalled
                return
            }
            status = .ready
            if !UserDefaults.standard.bool(forKey: Self.prefKey) {
                useAdvancedModel = true
            }
            print("[ModelManager] Model found at: \(file.path) (version \(Self.currentModelVersion))")
            warmUp()
        } else {
            status = .notInstalled
            print("[ModelManager] Model not found at: \(file.path)")
        }
    }

    /// Removes the installed model from disk to free space.
    func deleteModel() {
        let file = Self.modelsDirectory.appendingPathComponent(Self.compiledModelName)
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: Self.versionSidecarURL)
        cachedModel = nil
        status = .notInstalled
        useAdvancedModel = false
        print("[ModelManager] Model deleted")
    }

    /// Formatted total size of the installed model directory, or nil if not present.
    var installedSize: String? {
        let dir = Self.modelsDirectory.appendingPathComponent(Self.compiledModelName)
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
        let totalBytes = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]
        ).reduce(into: Int64(0)) { sum, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            sum += Int64(size)
        }) ?? 0
        guard totalBytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    // MARK: - Initialisation

    init() {
        let file = Self.modelsDirectory.appendingPathComponent(Self.compiledModelName)
        if FileManager.default.fileExists(atPath: file.path) {
            if installedModelVersion == Self.currentModelVersion {
                status = .ready
                warmUp()
            } else {
                print("[ModelManager] Stale model version on disk — scheduling refresh")
                Task { @MainActor [weak self] in self?.refresh() }
            }
        }
    }

    // MARK: - Private

    private var cachedModel: MLModel?
    private var downloadTask: URLSessionDownloadTask?
    private var downloadDelegate: DownloadDelegate?

    private static let prefKey = "useAdvancedHairModel"
    private static let hintDismissedKey = "advancedModelHintDismissed"

    /// The compiled CoreML model directory name.
    static let compiledModelName = "BiRefNet.mlmodelc"

    /// Identifier for the expected model build. Bumped whenever the released
    /// `.mlmodelc` changes (new weights, new preprocessing, etc.). Existing
    /// users with a mismatching install will be auto-migrated on launch.
    /// v2 swaps the generic DIS BiRefNet weights for the portrait fine-tune
    /// and bakes ImageNet normalization into the CoreML input.
    static let currentModelVersion = "v2"

    /// Filename of the version sidecar written next to the .mlmodelc on install.
    private static let versionSidecarName = ".model_version"

    private static var versionSidecarURL: URL {
        modelsDirectory.appendingPathComponent(versionSidecarName)
    }

    /// URL of the pre-compiled model archive. Bumping the path component
    /// (e.g. `birefnet-v2`) isolates each release so existing v1 users who
    /// migrate don't hit cached CDN copies of the old build.
    static let modelDownloadURL = URL(string: "https://github.com/thierrzz/Avatar/releases/download/birefnet-\(currentModelVersion)/BiRefNet.mlmodelc.zip")!

    /// Reads the version string written into the models directory at install
    /// time. Returns nil when no sidecar is present (e.g. v1 installs, which
    /// predate version tracking).
    private var installedModelVersion: String? {
        guard let data = try? Data(contentsOf: Self.versionSidecarURL),
              let s = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else { return nil }
        return s
    }

    static var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("Avatar")
            .appendingPathComponent("Models")
    }

    /// Extracts a downloaded zip archive into the models directory.
    private func extractAndInstall(from zipURL: URL) throws {
        let modelsDir = Self.modelsDirectory
        try FileManager.default.createDirectory(at: modelsDir,
                                                 withIntermediateDirectories: true)

        let destDir = modelsDir.appendingPathComponent(Self.compiledModelName)
        if FileManager.default.fileExists(atPath: destDir.path) {
            try FileManager.default.removeItem(at: destDir)
        }

        // Use macOS built-in ditto to extract the zip archive.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-xk", zipURL.path, modelsDir.path]
        process.standardOutput = nil
        process.standardError = nil
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw NSError(domain: "ModelManager", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                                        Loc.extractionFailed(process.terminationStatus)])
        }
        guard FileManager.default.fileExists(atPath: destDir.path) else {
            throw NSError(domain: "ModelManager", code: 2,
                          userInfo: [NSLocalizedDescriptionKey:
                                        Loc.modelNotFoundAfterExtract])
        }
        // Stamp the install with the current model version so future launches
        // can detect and auto-migrate stale builds.
        try? Self.currentModelVersion.write(to: Self.versionSidecarURL,
                                            atomically: true, encoding: .utf8)
        print("[ModelManager] Extracted model to: \(destDir.path) (version \(Self.currentModelVersion))")
    }
}

// MARK: - URLSession Download Delegate

/// Bridges URLSession download callbacks to the @Observable ModelManager.
private class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    var onProgress: ((Double) -> Void)?
    var onComplete: ((URL?, Error?) -> Void)?

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The temp file is deleted when this method returns — copy it first.
        let tempCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".zip")
        do {
            try FileManager.default.copyItem(at: location, to: tempCopy)
            onComplete?(tempCopy, nil)
        } catch {
            onComplete?(nil, error)
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress?(progress)
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error {
            onComplete?(nil, error)
        }
    }
}
