// Sparkle-updater voor Avatar2 (E01.11) — 1-op-1 port van de v1
// `Avatar/Services/UpdateManager.swift` (zelfde self-hosted appcast + EdDSA-
// publieke sleutel, zie project.yml). Wrappt SPUUpdater met een eigen
// in-app user-driver zodat de About-pagina (E15.4) check/auto-check stuurt
// zonder Sparkle's eigen vensters. De v1-`#if !APP_STORE`-gate is hier weg:
// Avatar2 is voorlopig DMG-only; een latere MAS-target sluit dit bestand uit.
//
// E13.5 (audit-C1): de manager is nu app-breed — Avatar2App bezit de ENIGE
// instance (@State) en geeft hem via Environment door; SettingsAboutPage
// consumeert die. Sparkle verwacht één SPUUpdater per proces, dus hier mag
// nooit meer per-view geconstrueerd worden. De SPUUpdater zit achter het
// `UpdaterEngine`-seam zodat de launch-checklogica zonder echte Sparkle
// testbaar is (Avatar2Tests/UpdateManagerTests.swift) en de unit-test-host
// nooit een echte updater start.

import Foundation
import SwiftUI
import Combine
import Sparkle

enum UpdateState: Equatable {
    case idle
    /// Laatste handmatige check vond geen update; blijft staan tot de
    /// volgende check zodat "Check now" zichtbaar iets opgeleverd heeft.
    case upToDate
    case checking
    /// Update gevonden; wacht op de keuze van de gebruiker (kaart linksonder:
    /// Install Update / Later). Ook bij achtergrondchecks — een update wordt
    /// nooit stil gedownload of stil verborgen.
    case available(version: String)
    /// `progress` 0…1; nil zolang Sparkle de totale grootte nog niet kent.
    case downloading(version: String, progress: Double?)
    case extracting(version: String)
    case readyToRelaunch(version: String)
    /// Achtergrond-/handmatige check mislukt (appcast onbereikbaar e.d.).
    /// Bewust niet in de kaart: staat alleen in Settings → About.
    case error(String)
    /// De gebruiker koos Install/Relaunch en Sparkle kon de update daarna niet
    /// downloaden, verifiëren of installeren (E13.8). Dít hoort wél in de
    /// kaart, mét reden — "de kaart verdwijnt en er gebeurt niets" is precies
    /// hoe de sandbox-bug van 2.0.0/2.0.1 onzichtbaar bleef.
    case installFailed(version: String, message: String)
}

/// Wat de update-kaart (linksonder, bij de sidebar) toont. Identiteit zónder
/// voortgang: de kaart leest de voortgang zelf uit de manager, zodat een
/// procent-tik de zwevende toast niet steeds opnieuw naar voren haalt.
enum UpdateToastItem: Equatable {
    case available(version: String)
    case downloading(version: String)
    case extracting(version: String)
    case ready(version: String)
    case failed(version: String)
}

// MARK: - Engine-seam (E13.5)

/// Dun laagje over `SPUUpdater` zodat `UpdateManager` in tests een fake
/// engine kan krijgen (geen echte Sparkle-start / netwerk in unit-tests).
@MainActor
protocol UpdaterEngine: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var canCheckForUpdates: Bool { get }
    var canCheckForUpdatesPublisher: AnyPublisher<Bool, Never> { get }
    var lastUpdateCheckDate: Date? { get }
    func start() throws
    func checkForUpdates()
}

/// Productie-engine: de echte `SPUUpdater` op de main bundle.
@MainActor
private final class SparkleUpdaterEngine: UpdaterEngine {
    private let updater: SPUUpdater

    init(userDriver: any SPUUserDriver) {
        updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: userDriver,
            delegate: nil
        )
    }

    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    var canCheckForUpdates: Bool { updater.canCheckForUpdates }

    var canCheckForUpdatesPublisher: AnyPublisher<Bool, Never> {
        updater.publisher(for: \.canCheckForUpdates).eraseToAnyPublisher()
    }

    var lastUpdateCheckDate: Date? { updater.lastUpdateCheckDate }

    func start() throws { try updater.start() }
    func checkForUpdates() { updater.checkForUpdates() }
}

/// No-op-engine voor de unit-test-host: Avatar2Tests draait gehost in
/// Aaavatar.app (Avatar2-product), dus `Avatar2App.init` (en dus `UpdateManager()`) draait
/// óók tijdens `xcodebuild test`. Daar mag nooit een echte SPUUpdater
/// starten (netwerk-check tegen de appcast midden in een testrun).
@MainActor
private final class NoopUpdaterEngine: UpdaterEngine {
    var automaticallyChecksForUpdates = true
    var canCheckForUpdates = true
    var canCheckForUpdatesPublisher: AnyPublisher<Bool, Never> {
        Empty().eraseToAnyPublisher()
    }
    var lastUpdateCheckDate: Date? { nil }
    func start() throws {}
    func checkForUpdates() {}
}

// MARK: - UpdateManager

@MainActor
@Observable
final class UpdateManager: NSObject {
    private(set) var state: UpdateState = .idle
    /// Mirrors `SPUUpdater.canCheckForUpdates`. Defaults to `true` so the
    /// "Check Now" button is enabled at first paint, before Sparkle's KVO
    /// has had a chance to publish.
    private(set) var canCheckForUpdates = true
    private var engine: (any UpdaterEngine)!
    private var userDriver: InAppUserDriver!

    @ObservationIgnored
    private var cancellables = Set<AnyCancellable>()

    /// Kaart linksonder (Avatar2App → `.dsFloatingToast`). nil = geen kaart.
    /// Check-fouten blijven buiten de kaart (Settings → About): een
    /// achtergrondcheck mag geen nag worden. Een mislukte installatie ná een
    /// klik op Install/Relaunch komt wél in de kaart (besluit Thierry
    /// 2026-09-06): de gebruiker heeft iets gevraagd en krijgt antwoord.
    var toastItem: UpdateToastItem? {
        switch state {
        case .available(let version): return .available(version: version)
        case .downloading(let version, _): return .downloading(version: version)
        case .extracting(let version): return .extracting(version: version)
        case .readyToRelaunch(let version): return .ready(version: version)
        case .installFailed(let version, _): return .failed(version: version)
        case .idle, .upToDate, .checking, .error: return nil
        }
    }

    var automaticallyChecksForUpdates: Bool {
        get { engine?.automaticallyChecksForUpdates ?? true }
        set { engine?.automaticallyChecksForUpdates = newValue }
    }

    var lastUpdateCheckDate: Date? {
        engine?.lastUpdateCheckDate
    }

    /// - Parameter makeEngine: test-seam; default is de echte Sparkle-engine
    ///   (of een no-op wanneer we als unit-test-host draaien, zie
    ///   `NoopUpdaterEngine`).
    init(makeEngine: ((any SPUUserDriver) -> any UpdaterEngine)? = nil) {
        super.init()
        userDriver = InAppUserDriver(manager: self)
        if let makeEngine {
            engine = makeEngine(userDriver)
        } else if NSClassFromString("XCTestCase") != nil {
            engine = NoopUpdaterEngine()
        } else {
            engine = SparkleUpdaterEngine(userDriver: userDriver)
        }
        do {
            try engine.start()
            canCheckForUpdates = engine.canCheckForUpdates
        } catch {
            state = .error(error.localizedDescription)
        }

        engine.canCheckForUpdatesPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.canCheckForUpdates = value
            }
            .store(in: &cancellables)
    }

    func checkForUpdates() {
        engine.checkForUpdates()
    }

    // Geen handmatige achtergrondcheck bij launch meer (2026-09-02). Sparkle
    // plant die zelf zodra `automaticallyChecksForUpdates` aan staat
    // (SUEnableAutomaticChecks + SUScheduledCheckInterval); onze extra call
    // botste met Sparkle's eigen start-cyclus ("sessionInProgress == YES" in
    // het log) en werd dan stil genegeerd.

    /// Kaart: "Install Update" — Sparkle gaat downloaden.
    func installAvailableUpdate() {
        userDriver.chooseInstall()
    }

    /// Kaart: "Later" — Sparkle sluit deze cyclus; de volgende geplande check
    /// biedt de update opnieuw aan. Bij een al gedownloade update (ready)
    /// installeert Sparkle 'm bij het afsluiten van de app.
    func dismissAvailableUpdate() {
        userDriver.chooseDismiss()
    }

    /// Kaart: "Cancel" tijdens de download.
    func cancelDownload() {
        userDriver.cancelDownload()
    }

    func relaunchAndInstall() {
        userDriver.confirmInstallAndRelaunch()
    }

    /// Kaart (mislukt): "Try again" — Sparkle heeft de sessie al afgesloten,
    /// dus een nieuwe check start een verse cyclus (download opnieuw).
    func retryFailedUpdate() {
        guard case .installFailed = state else { return }
        state = .idle
        engine.checkForUpdates()
    }

    /// Kaart (mislukt): "Dismiss".
    func dismissFailedUpdate() {
        guard case .installFailed = state else { return }
        state = .idle
    }

    /// Intern (niet fileprivate) zodat de tests de kaart-mapping kunnen toetsen.
    func updateState(_ newState: UpdateState) {
        state = newState
    }

    /// Sparkle's `dismissUpdateInstallation` volgt direct op "geen update
    /// gevonden" én op een fout (ná de acknowledgement); die uitkomsten mogen
    /// daarbij niet meteen weer verdwijnen — de gebruiker sluit ze zelf of de
    /// volgende check overschrijft ze.
    fileprivate func settleAfterDismiss() {
        switch state {
        case .upToDate, .error, .installFailed: break
        default: state = .idle
        }
    }
}

// MARK: - Custom SPUUserDriver

private final class InAppUserDriver: NSObject, SPUUserDriver {
    private weak var manager: UpdateManager?
    /// Reply van `showUpdateFound` (Install/Later) óf van `showReady`
    /// (Relaunch/Later) — Sparkle wacht erop; precies één keer beantwoorden.
    private var pendingReply: ((SPUUserUpdateChoice) -> Void)?
    private var downloadCancellation: (() -> Void)?
    /// true zodra de gebruiker Install (of Relaunch) koos: een fout daarna is
    /// een mislukte installatie (kaart), níet een mislukte check (About).
    private var installRequested = false
    private var cachedNewVersion: String?
    private var expectedLength: UInt64 = 0
    private var receivedLength: UInt64 = 0
    private var lastReportedProgress: Double = -1

    init(manager: UpdateManager) {
        self.manager = manager
    }

    private var version: String { cachedNewVersion ?? "" }

    // MARK: keuzes vanuit de kaart

    func chooseInstall() {
        if pendingReply != nil { installRequested = true }
        pendingReply?(.install)
        pendingReply = nil
    }

    func chooseDismiss() {
        pendingReply?(.dismiss)
        pendingReply = nil
    }

    func cancelDownload() {
        downloadCancellation?()
        downloadCancellation = nil
    }

    func confirmInstallAndRelaunch() {
        chooseInstall()
    }

    // MARK: SPUUserDriver

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
        installRequested = false
        pendingReply = reply
        let version = appcastItem.displayVersionString
        Task { @MainActor in manager?.updateState(.available(version: version)) }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error,
                                     acknowledgement: @escaping () -> Void) {
        Task { @MainActor in manager?.updateState(.upToDate) }
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let message = Self.userFacingMessage(for: error)
        let newState: UpdateState = installRequested
            ? .installFailed(version: version, message: message)
            : .error(message)
        Task { @MainActor in manager?.updateState(newState) }
        acknowledgement()
    }

    /// Sparkle's `localizedDescription` is vaak generiek ("An error occurred
    /// while running the updater. Please try again later."); de échte reden
    /// zit in `localizedFailureReason`. Beide tonen, zodat "waarom" in de kaart
    /// staat en niet alleen in Console.
    static func userFacingMessage(for error: Error) -> String {
        let nsError = error as NSError
        var message = error.localizedDescription
        if let reason = nsError.localizedFailureReason, !reason.isEmpty, reason != message {
            message += "\n" + reason
        }
        return message
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        downloadCancellation = cancellation
        expectedLength = 0
        receivedLength = 0
        lastReportedProgress = -1
        let version = version
        Task { @MainActor in manager?.updateState(.downloading(version: version, progress: nil)) }
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedLength = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedLength += length
        guard expectedLength > 0 else { return }
        let progress = min(1, Double(receivedLength) / Double(expectedLength))
        // Hele procenten: een state-update per chunk zou de kaart onnodig
        // vaak laten hertekenen.
        guard progress - lastReportedProgress >= 0.01 || progress == 1 else { return }
        lastReportedProgress = progress
        let version = version
        Task { @MainActor in manager?.updateState(.downloading(version: version, progress: progress)) }
    }

    func showDownloadDidStartExtractingUpdate() {
        downloadCancellation = nil
        let version = version
        Task { @MainActor in manager?.updateState(.extracting(version: version)) }
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        pendingReply = reply
        let version = version
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
        pendingReply = nil
        downloadCancellation = nil
        installRequested = false
        cachedNewVersion = nil
        Task { @MainActor in manager?.settleAfterDismiss() }
    }
}
