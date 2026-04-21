import Foundation
import CoreML

/// Manages the optional Real-ESRGAN Core ML super-resolution models used by the
/// Upscale button. Two independent variants (2× and 4×) can be installed side
/// by side; the user picks which one runs. Mirrors `ModelManager` (BiRefNet)
/// in shape and on-disk layout, but tracks per-variant status because the
/// download, cache, and availability are independent.
@MainActor
@Observable
final class UpscaleModelManager {

    // MARK: - Variants

    enum Variant: String, CaseIterable, Identifiable {
        case x2
        case x4

        var id: String { rawValue }

        /// Integer scale factor the model applies.
        var factor: Int {
            switch self {
            case .x2: return 2
            case .x4: return 4
            }
        }

        /// Name of the compiled model directory on disk.
        var compiledModelName: String {
            switch self {
            case .x2: return "RealESRGAN_x2.mlmodelc"
            case .x4: return "RealESRGAN_x4.mlmodelc"
            }
        }

        /// Version identifier bumped when the released asset changes.
        var currentVersion: String {
            switch self {
            case .x2: return "v1"
            case .x4: return "v1"
            }
        }

        /// Release tag / URL the downloader pulls from. The tag embeds the
        /// version so CDN caches don't serve stale builds after a bump.
        var downloadURL: URL {
            switch self {
            case .x2:
                return URL(string: "https://github.com/thierrzz/Avatar/releases/download/realesrgan-x2-\(currentVersion)/RealESRGAN_x2.mlmodelc.zip")!
            case .x4:
                return URL(string: "https://github.com/thierrzz/Avatar/releases/download/realesrgan-x4-\(currentVersion)/RealESRGAN_x4.mlmodelc.zip")!
            }
        }

        /// Hidden sidecar file alongside the `.mlmodelc` that stamps the
        /// installed version string.
        var versionSidecarName: String {
            switch self {
            case .x2: return ".realesrgan_x2_version"
            case .x4: return ".realesrgan_x4_version"
            }
        }
    }

    // MARK: - Public state

    enum Status: Equatable {
        case notInstalled
        case downloading(progress: Double)
        case ready
        case error(String)
    }

    /// Per-variant status. Accessed in SwiftUI via `status(for:)`.
    private(set) var statusX2: Status = .notInstalled
    private(set) var statusX4: Status = .notInstalled

    func status(for variant: Variant) -> Status {
        switch variant {
        case .x2: return statusX2
        case .x4: return statusX4
        }
    }

    /// True when at least one variant is ready to use — feature gate for the
    /// Upscale button.
    var isAnyInstalled: Bool {
        statusX2 == .ready || statusX4 == .ready
    }

    /// Whether any variant is currently downloading — used to disable the
    /// global upscale button while a download is in flight.
    var isDownloading: Bool {
        if case .downloading = statusX2 { return true }
        if case .downloading = statusX4 { return true }
        return false
    }

    /// User's preferred variant. Respected when both are installed; otherwise
    /// `activeModelAsync()` falls through to whichever variant is ready.
    var selectedVariant: Variant {
        get {
            if let raw = UserDefaults.standard.string(forKey: Self.variantPrefKey),
               let v = Variant(rawValue: raw) {
                return v
            }
            return .x4
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.variantPrefKey)
        }
    }

    // MARK: - Model access

    /// Returns the variant the user wants and, if it's installed, its loaded
    /// model. Falls through to the other variant when the preferred one isn't
    /// available. Returns nil only when no variant is installed.
    func activeModelAsync() async -> (model: MLModel, variant: Variant)? {
        let preferred = selectedVariant
        if status(for: preferred) == .ready,
           let model = await loadModelAsync(preferred) {
            return (model, preferred)
        }
        let other: Variant = preferred == .x2 ? .x4 : .x2
        if status(for: other) == .ready,
           let model = await loadModelAsync(other) {
            return (model, other)
        }
        return nil
    }

    /// Loads (or returns cached) compiled model for the given variant. Performs
    /// the heavy `MLModel.init` on a background executor so the first load
    /// doesn't freeze the UI.
    func loadModelAsync(_ variant: Variant) async -> MLModel? {
        guard status(for: variant) == .ready else { return nil }
        if let cached = cachedModel[variant] { return cached }

        let compiledURL = Self.modelsDirectory.appendingPathComponent(variant.compiledModelName)
        guard FileManager.default.fileExists(atPath: compiledURL.path) else {
            setStatus(.notInstalled, for: variant)
            return nil
        }

        do {
            let model = try await Self.loadCompiled(at: compiledURL)
            cachedModel[variant] = model
            return model
        } catch {
            print("[UpscaleModelManager] Failed to load \(variant.rawValue): \(error)")
            setStatus(.error(Loc.upscaleModelLoadFailed(error.localizedDescription)), for: variant)
            return nil
        }
    }

    nonisolated private static func loadCompiled(at url: URL) async throws -> MLModel {
        try await Task.detached(priority: .userInitiated) {
            let config = MLModelConfiguration()
            config.computeUnits = .all
            return try MLModel(contentsOf: url, configuration: config)
        }.value
    }

    // MARK: - Download & install

    /// Starts a background download of the selected variant. No-op while
    /// already downloading.
    func downloadAndInstall(_ variant: Variant) {
        if case .downloading = status(for: variant) { return }

        // Skip the download if the expected version is already on disk.
        let existing = Self.modelsDirectory.appendingPathComponent(variant.compiledModelName)
        if FileManager.default.fileExists(atPath: existing.path),
           installedVersion(for: variant) == variant.currentVersion {
            setStatus(.ready, for: variant)
            warmUp(variant)
            print("[UpscaleModelManager] \(variant.rawValue) already on disk, skipping download")
            return
        }

        setStatus(.downloading(progress: 0), for: variant)

        let delegate = DownloadDelegate()
        delegate.onProgress = { [weak self] progress in
            Task { @MainActor in
                self?.setStatus(.downloading(progress: progress), for: variant)
            }
        }
        delegate.onComplete = { [weak self] tempURL, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    if (error as NSError).code == NSURLErrorCancelled {
                        self.setStatus(.notInstalled, for: variant)
                    } else {
                        self.setStatus(.error(Loc.downloadFailed(error.localizedDescription)), for: variant)
                    }
                    return
                }
                guard let tempURL else {
                    self.setStatus(.error(Loc.downloadNoFile), for: variant)
                    return
                }
                do {
                    try self.extractAndInstall(from: tempURL, variant: variant)
                    try? FileManager.default.removeItem(at: tempURL)
                    self.setStatus(.ready, for: variant)
                    print("[UpscaleModelManager] \(variant.rawValue) downloaded and installed")
                } catch {
                    try? FileManager.default.removeItem(at: tempURL)
                    self.setStatus(.error(Loc.installFailed(error.localizedDescription)), for: variant)
                    print("[UpscaleModelManager] \(variant.rawValue) install failed: \(error)")
                }
            }
        }
        downloadDelegates[variant] = delegate

        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: variant.downloadURL)
        downloadTasks[variant] = task
        task.resume()
        print("[UpscaleModelManager] Download started for \(variant.rawValue): \(variant.downloadURL)")
    }

    func cancelDownload(_ variant: Variant) {
        downloadTasks[variant]?.cancel()
        downloadTasks[variant] = nil
        downloadDelegates[variant] = nil
        setStatus(.notInstalled, for: variant)
        print("[UpscaleModelManager] \(variant.rawValue) download cancelled")
    }

    // MARK: - Refresh / delete

    /// Re-scans the disk for an installed model and auto-migrates stale builds
    /// (mismatching version sidecar) by removing them.
    func refresh(_ variant: Variant) {
        cachedModel[variant] = nil
        let file = Self.modelsDirectory.appendingPathComponent(variant.compiledModelName)
        if FileManager.default.fileExists(atPath: file.path) {
            if installedVersion(for: variant) != variant.currentVersion {
                print("[UpscaleModelManager] \(variant.rawValue) stale version, removing")
                try? FileManager.default.removeItem(at: file)
                try? FileManager.default.removeItem(at: sidecarURL(for: variant))
                setStatus(.notInstalled, for: variant)
                return
            }
            setStatus(.ready, for: variant)
            warmUp(variant)
        } else {
            setStatus(.notInstalled, for: variant)
        }
    }

    func refreshAll() {
        for v in Variant.allCases { refresh(v) }
    }

    func deleteModel(_ variant: Variant) {
        let file = Self.modelsDirectory.appendingPathComponent(variant.compiledModelName)
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: sidecarURL(for: variant))
        cachedModel[variant] = nil
        setStatus(.notInstalled, for: variant)
        print("[UpscaleModelManager] \(variant.rawValue) deleted")
    }

    func warmUp(_ variant: Variant) {
        guard status(for: variant) == .ready, cachedModel[variant] == nil else { return }
        Task { [weak self] in
            _ = await self?.loadModelAsync(variant)
            print("[UpscaleModelManager] \(variant.rawValue) warm-up complete")
        }
    }

    /// Size of the installed compiled model directory, or nil when absent.
    func installedSize(for variant: Variant) -> String? {
        let dir = Self.modelsDirectory.appendingPathComponent(variant.compiledModelName)
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
        let total = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]
        ).reduce(into: Int64(0)) { sum, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            sum += Int64(size)
        }) ?? 0
        guard total > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    // MARK: - Init

    init() {
        for variant in Variant.allCases {
            let file = Self.modelsDirectory.appendingPathComponent(variant.compiledModelName)
            if FileManager.default.fileExists(atPath: file.path) {
                if installedVersion(for: variant) == variant.currentVersion {
                    setStatus(.ready, for: variant)
                    warmUp(variant)
                } else {
                    Task { @MainActor [weak self] in self?.refresh(variant) }
                }
            }
        }
    }

    // MARK: - Private helpers

    private var cachedModel: [Variant: MLModel] = [:]
    private var downloadTasks: [Variant: URLSessionDownloadTask] = [:]
    private var downloadDelegates: [Variant: DownloadDelegate] = [:]

    private static let variantPrefKey = "upscaleSelectedVariant"

    static var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("Avatar")
            .appendingPathComponent("Models")
    }

    private func setStatus(_ new: Status, for variant: Variant) {
        switch variant {
        case .x2: statusX2 = new
        case .x4: statusX4 = new
        }
    }

    private func sidecarURL(for variant: Variant) -> URL {
        Self.modelsDirectory.appendingPathComponent(variant.versionSidecarName)
    }

    private func installedVersion(for variant: Variant) -> String? {
        guard let data = try? Data(contentsOf: sidecarURL(for: variant)),
              let s = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else { return nil }
        return s
    }

    private func extractAndInstall(from zipURL: URL, variant: Variant) throws {
        let modelsDir = Self.modelsDirectory
        try FileManager.default.createDirectory(at: modelsDir,
                                                 withIntermediateDirectories: true)

        let destDir = modelsDir.appendingPathComponent(variant.compiledModelName)
        if FileManager.default.fileExists(atPath: destDir.path) {
            try FileManager.default.removeItem(at: destDir)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-xk", zipURL.path, modelsDir.path]
        process.standardOutput = nil
        process.standardError = nil
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw NSError(domain: "UpscaleModelManager", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                                        Loc.extractionFailed(process.terminationStatus)])
        }
        guard FileManager.default.fileExists(atPath: destDir.path) else {
            throw NSError(domain: "UpscaleModelManager", code: 2,
                          userInfo: [NSLocalizedDescriptionKey:
                                        Loc.modelNotFoundAfterExtract])
        }
        try? variant.currentVersion.write(to: sidecarURL(for: variant),
                                          atomically: true, encoding: .utf8)
    }
}

// MARK: - URLSession delegate (file-private, shared shape with ModelManager)

private class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    var onProgress: ((Double) -> Void)?
    var onComplete: ((URL?, Error?) -> Void)?

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
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
        onProgress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error {
            onComplete?(nil, error)
        }
    }
}
