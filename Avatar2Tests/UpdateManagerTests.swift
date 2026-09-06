// E13.5 (audit-C1) — UpdateManager app-breed. De echte SPUUpdater zit achter
// het `UpdaterEngine`-seam; hier prikken we een fake engine in en toetsen we
// precies één engine-start, het doorgeefgedrag van About, en (2026-09-02) de
// mapping van de update-state naar de kaart linksonder. De handmatige
// launch-achtergrondcheck is vervallen: Sparkle plant die zelf (zie
// UpdateManager). Geen echte Sparkle/netwerk in deze tests.

import Combine
import XCTest
@testable import Avatar2

@MainActor
private final class FakeUpdaterEngine: UpdaterEngine {
    var automaticallyChecksForUpdates = true
    var canCheckForUpdates = true
    var lastUpdateCheckDate: Date?

    let canCheckSubject = PassthroughSubject<Bool, Never>()
    var canCheckForUpdatesPublisher: AnyPublisher<Bool, Never> {
        canCheckSubject.eraseToAnyPublisher()
    }

    private(set) var startCount = 0
    private(set) var userCheckCount = 0

    func start() throws { startCount += 1 }
    func checkForUpdates() { userCheckCount += 1 }
}

@MainActor
final class UpdateManagerTests: XCTestCase {

    private func maakManager(
        engine: FakeUpdaterEngine
    ) -> UpdateManager {
        UpdateManager(makeEngine: { _ in engine })
    }

    // MARK: - init

    func testInitStartDeEnginePreciesEenKeer() {
        let engine = FakeUpdaterEngine()
        _ = maakManager(engine: engine)
        XCTAssertEqual(engine.startCount, 1)
        XCTAssertEqual(engine.userCheckCount, 0,
                       "init zelf mag nog geen check triggeren")
    }

    // MARK: - update-kaart (linksonder)

    func testKaartVolgtDeStateZonderVoortgangInDeIdentiteit() {
        let manager = maakManager(engine: FakeUpdaterEngine())
        XCTAssertNil(manager.toastItem, "idle → geen kaart")

        manager.updateState(.checking)
        XCTAssertNil(manager.toastItem, "checken is stil; geen kaart")

        manager.updateState(.available(version: "2.0.1"))
        XCTAssertEqual(manager.toastItem, .available(version: "2.0.1"))

        manager.updateState(.downloading(version: "2.0.1", progress: 0.3))
        let first = manager.toastItem
        manager.updateState(.downloading(version: "2.0.1", progress: 0.6))
        XCTAssertEqual(first, manager.toastItem,
                       "een procent-tik verandert de kaart-identiteit niet")
        XCTAssertEqual(manager.toastItem, .downloading(version: "2.0.1"))

        manager.updateState(.extracting(version: "2.0.1"))
        XCTAssertEqual(manager.toastItem, .extracting(version: "2.0.1"))

        manager.updateState(.readyToRelaunch(version: "2.0.1"))
        XCTAssertEqual(manager.toastItem, .ready(version: "2.0.1"))

        manager.updateState(.error("boom"))
        XCTAssertNil(manager.toastItem, "check-fouten horen in About, niet in de kaart")

        manager.updateState(.installFailed(version: "2.0.1", message: "boom"))
        XCTAssertEqual(manager.toastItem, .failed(version: "2.0.1"),
                       "een mislukte installatie mag nooit stil verdwijnen (E13.8)")

        manager.updateState(.upToDate)
        XCTAssertNil(manager.toastItem)
    }

    func testMislukteInstallatieTryAgainStartNieuweCheckEnDismissSluitDeKaart() {
        let engine = FakeUpdaterEngine()
        let manager = maakManager(engine: engine)

        manager.updateState(.installFailed(version: "2.0.1", message: "boom"))
        manager.retryFailedUpdate()
        XCTAssertEqual(manager.state, .idle)
        XCTAssertEqual(engine.userCheckCount, 1, "Try again = verse Sparkle-cyclus")

        manager.updateState(.installFailed(version: "2.0.1", message: "boom"))
        manager.dismissFailedUpdate()
        XCTAssertEqual(manager.state, .idle)
        XCTAssertNil(manager.toastItem)

        // Buiten de mislukt-state zijn beide no-ops (geen extra check).
        manager.updateState(.available(version: "2.0.1"))
        manager.retryFailedUpdate()
        manager.dismissFailedUpdate()
        XCTAssertEqual(manager.state, .available(version: "2.0.1"))
        XCTAssertEqual(engine.userCheckCount, 1)
    }

    func testKaartKeuzesZonderOpenSparkleVraagZijnVeilig() {
        let manager = maakManager(engine: FakeUpdaterEngine())
        // Geen pending reply/cancellation → geen crash, state ongemoeid.
        manager.installAvailableUpdate()
        manager.dismissAvailableUpdate()
        manager.cancelDownload()
        manager.relaunchAndInstall()
        XCTAssertEqual(manager.state, .idle)
    }

    // MARK: - doorgeefgedrag About-pagina

    func testCheckForUpdatesGaatNaarDeEngine() {
        let engine = FakeUpdaterEngine()
        let manager = maakManager(engine: engine)
        manager.checkForUpdates()
        XCTAssertEqual(engine.userCheckCount, 1)
    }

    func testAutomaticallyChecksForUpdatesSpiegeltDeEngine() {
        let engine = FakeUpdaterEngine()
        let manager = maakManager(engine: engine)
        XCTAssertTrue(manager.automaticallyChecksForUpdates)
        manager.automaticallyChecksForUpdates = false
        XCTAssertFalse(engine.automaticallyChecksForUpdates)
    }

    func testCanCheckForUpdatesVolgtDePublisher() async {
        let engine = FakeUpdaterEngine()
        let manager = maakManager(engine: engine)
        XCTAssertTrue(manager.canCheckForUpdates)

        engine.canCheckSubject.send(false)
        // sink levert via DispatchQueue.main — één hop wachten.
        let hop = expectation(description: "main-queue hop")
        DispatchQueue.main.async { hop.fulfill() }
        await fulfillment(of: [hop], timeout: 2)

        XCTAssertFalse(manager.canCheckForUpdates)
    }
}
