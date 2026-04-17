import Foundation
import SwiftUI
import Combine
import Sparkle

enum UpdateState: Equatable {
    case idle
    case checking
    case downloading(progress: Double)
    case extracting
    case readyToRelaunch(version: String)
    case error(String)
}

@MainActor
@Observable
final class UpdateManager: NSObject {
    private(set) var state: UpdateState = .idle
    private(set) var canCheckForUpdates = false

    private var updater: SPUUpdater!
    private var userDriver: InAppUserDriver!

    @ObservationIgnored
    private var cancellables = Set<AnyCancellable>()

    var automaticallyChecksForUpdates: Bool {
        get { updater?.automaticallyChecksForUpdates ?? true }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }

    var lastUpdateCheckDate: Date? {
        updater?.lastUpdateCheckDate
    }

    override init() {
        super.init()
        userDriver = InAppUserDriver(manager: self)
        updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: userDriver,
            delegate: nil
        )
        do {
            try updater.start()
        } catch {
            state = .error(error.localizedDescription)
        }

        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.canCheckForUpdates = value
            }
            .store(in: &cancellables)
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }

    func checkForUpdatesInBackground() {
        updater.checkForUpdatesInBackground()
    }

    func relaunchAndInstall() {
        userDriver.confirmInstallAndRelaunch()
    }

    fileprivate func updateState(_ newState: UpdateState) {
        state = newState
    }
}

// MARK: - Custom SPUUserDriver

private final class InAppUserDriver: NSObject, SPUUserDriver {
    private weak var manager: UpdateManager?
    private var installReply: ((SPUUserUpdateChoice) -> Void)?
    private var cachedNewVersion: String?

    init(manager: UpdateManager) {
        self.manager = manager
    }

    func confirmInstallAndRelaunch() {
        installReply?(.install)
        installReply = nil
    }

    // MARK: SPUUserDriver — Required Methods

    func show(_ request: SPUUpdatePermissionRequest,
              reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(.init(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        Task { @MainActor in manager?.updateState(.checking) }
    }

    func showUpdateFound(with appcastItem: SUAppcastItem,
                         state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        cachedNewVersion = appcastItem.displayVersionString
        reply(.install)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error,
                                     acknowledgement: @escaping () -> Void) {
        Task { @MainActor in manager?.updateState(.idle) }
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        Task { @MainActor in manager?.updateState(.error(error.localizedDescription)) }
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        Task { @MainActor in manager?.updateState(.downloading(progress: 0)) }
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}

    func showDownloadDidReceiveData(ofLength length: UInt64) {}

    func showDownloadDidStartExtractingUpdate() {
        Task { @MainActor in manager?.updateState(.extracting) }
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        installReply = reply
        let version = cachedNewVersion ?? ""
        Task { @MainActor in manager?.updateState(.readyToRelaunch(version: version)) }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {}

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool,
                                          acknowledgement: @escaping () -> Void) {
        Task { @MainActor in manager?.updateState(.idle) }
        acknowledgement()
    }

    func showUpdateInFocus() {}

    func dismissUpdateInstallation() {
        installReply = nil
        cachedNewVersion = nil
        Task { @MainActor in manager?.updateState(.idle) }
    }
}
