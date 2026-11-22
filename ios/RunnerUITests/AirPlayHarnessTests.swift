import XCTest

/// Drives AirPlay end to end on a physical device, including the system route
/// sheet that Marionette can't reach: these tests are the hands, and the
/// app's sync trace (`scripts/pull_sync_trace.sh`) its own account of what
/// the player did. How to build and run them on the phone: the
/// `flutter-ios-native-verification` skill, "AirPlay and audio routes".
///
/// Settings come from the environment; through xcodebuild, prefix each with
/// `TEST_RUNNER_` (`TEST_RUNNER_PIECE="Lightly Row"`):
///   PIECE     piece title to open (default "Long, Long Ago")
///   RECEIVER  AirPlay receiver name, as the route sheet lists it (default "Kitchen")
///   SECTION   section chip to loop, or "All" (default "A")
///   MINUTES   how long testLoopOnAirPlay plays (default 5)
///   SKIP_ROUTE  set to skip picking the receiver (a simulator smoke run)
///   REPICK    set to pick the phone's speaker, then the receiver, even when
///             the receiver is already the route (a fresh connection)
///   VOLUME_UP "0" to leave the volume alone (default: 16 presses up)
final class AirPlayHarnessTests: XCTestCase {
  private let env = ProcessInfo.processInfo.environment
  private var piece: String { env["PIECE"] ?? "Long, Long Ago" }
  private var receiver: String { env["RECEIVER"] ?? "Kitchen" }
  private var section: String { env["SECTION"] ?? "A" }
  private var minutes: Double { Double(env["MINUTES"] ?? "") ?? 5 }

  private let app = XCUIApplication()

  override func setUp() {
    continueAfterFailure = false
  }

  private func log(_ s: String) {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    print("[harness] \(f.string(from: Date())) \(s)")
  }

  private func beginning(_ prefix: String) -> NSPredicate {
    NSPredicate(format: "label BEGINSWITH %@", prefix)
  }

  private var outputButton: XCUIElement {
    app.buttons.matching(beginning("Audio output")).firstMatch
  }

  /// Launches and opens [piece]. Waits for the transport's output button,
  /// which shows once the route is known: the piece is open and ready.
  private func openPiece() {
    app.launch()
    let row = app.staticTexts.matching(beginning(piece)).firstMatch
    // Flutter keeps off-screen rows in the tree with empty frames, so
    // "exists" isn't enough: scroll until the row is really on screen.
    func onScreen() -> Bool {
      row.exists && row.frame.height > 40 && row.frame.maxY < app.frame.maxY - 80
    }
    if !(row.waitForExistence(timeout: 20) && onScreen()) {
      app.buttons["All Pieces"].tap()
      sleep(1)
      var tries = 0
      while !onScreen() && tries < 30 {
        app.swipeUp(velocity: .slow)
        tries += 1
      }
    }
    XCTAssertTrue(onScreen(), "no piece titled \(piece) on screen")
    // The list can take a moment after launch to accept taps (seen on the
    // simulator: a tap at ~5s did nothing), so retry until the piece opens.
    for _ in 0..<4 {
      if !row.exists { break }
      row.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
      if outputButton.waitForExistence(timeout: 15) { break }
    }
    if !outputButton.waitForExistence(timeout: 30) {
      print("=== tree (no output button)\n\(app.debugDescription)")
      XCTFail("piece didn't open, or its transport has no output button")
    }
    log("opened \(piece); \(outputButton.label)")
  }

  /// The system route sheet is drawn out of process; look for the receiver's
  /// row in every place it might be listed.
  private func receiverRow(timeout: TimeInterval) -> XCUIElement? {
    routeRow(receiver, timeout: timeout)
  }

  private func routeRow(_ name: String, timeout: TimeInterval) -> XCUIElement? {
    let hosts = [
      app,
      // Not com.apple.MediaRemoteUI: querying it fails the test outright
      // (kAXErrorServerNotFound), whatever its .state says.
      XCUIApplication(bundleIdentifier: "com.apple.springboard"),
    ]
    let match = NSPredicate(format: "label CONTAINS %@", name)
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      for h in hosts {
        let e = h.descendants(matching: .any).matching(match)
          .allElementsBoundByIndex.first { $0.isHittable }
        if let e { return e }
      }
      sleep(1)
    } while Date() < deadline
    for h in hosts { print("=== tree of \(h)\n\(h.debugDescription)") }
    return nil
  }

  private func pickReceiver() {
    if env["SKIP_ROUTE"] != nil { return }  // simulator smoke run: no AirPlay there
    let repick = env["REPICK"] != nil
    if outputButton.label.contains(receiver) && !repick {
      log("already on \(receiver)")
      return
    }
    outputButton.tap()
    let change = app.buttons.matching(beginning("Change")).firstMatch
    XCTAssertTrue(change.waitForExistence(timeout: 5))
    change.tap()
    // REPICK: away to the phone's own speaker and back, for a fresh
    // connection. The cure for a stale speaker (CLAUDE.md, "Audio on iOS"
    // 6), reproduced with the Mac's receiver on 2026-11-22: the Mac
    // cancelled the session, the phone kept the route, every Play failed.
    if repick, let phone = routeRow("iPhone", timeout: 10) {
      log("re-pick: tapping '\(phone.label)' first")
      phone.tap()
      sleep(3)
      // Picking the phone's own speaker closes the system sheet: open it again.
      if routeRow(receiver, timeout: 3) == nil {
        closeSheets()
        if outputButton.waitForExistence(timeout: 10) { outputButton.tap() }
        let again = app.buttons.matching(beginning("Change")).firstMatch
        if again.waitForExistence(timeout: 5) { again.tap() }
      }
    }
    guard let row = receiverRow(timeout: 20) else {
      XCTFail("receiver \(receiver) not in the route sheet (trees printed above)")
      return
    }
    log("tapping route row '\(row.label)'")
    row.tap()
    // The system sheet stays up after a row is picked, hiding the app's
    // tree; let the route settle, then tap above the sheet to close it.
    sleep(4)
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap()
    log("app sees receiver name: \(app.staticTexts[receiver].waitForExistence(timeout: 15))")
    // App belief: the sheet's title is the route's port name.
    let ok = app.staticTexts[receiver].exists
    // Close the system sheet if it's still up, then the app's own sheet.
    sleep(2)
    closeSheets()
    // The button rebuilds on a route change (hidden while the route is null).
    if outputButton.waitForExistence(timeout: 15) {
      log("route now: \(outputButton.label)")
    } else {
      print("=== tree (no output button after pick)\n\(app.debugDescription)")
    }
    XCTAssertTrue(ok || outputButton.label.contains(receiver), "the app never reported \(receiver) as its route")
  }

  /// Media volume up, once playing: with nothing playing the volume buttons
  /// set the RINGER instead (seen on Jamz, 2026-11-22). Jamz's media volume
  /// was 0 (the sync trace's `vol=0.000`), so every run was silent.
  private func turnVolumeUp() {
    guard env["VOLUME_UP"] != "0" else { return }
    #if !targetEnvironment(simulator)  // no volume buttons there
    for _ in 0..<16 { XCUIDevice.shared.press(.volumeUp); usleep(150_000) }
    log("volume up x16")
    #endif
  }

  /// Closes the app's bottom sheet (and the system route sheet, if it is
  /// still up): tap the scrim above it, else flick it down. Tapping the
  /// sheet's drag handle ("Dismiss") does nothing.
  private func closeSheets() {
    for _ in 0..<4 {
      let scrim = app.staticTexts["Scrim"]
      guard scrim.exists || app.buttons["Dismiss"].exists else { return }
      if scrim.exists && scrim.isHittable {
        scrim.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
      } else {
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        top.press(forDuration: 0.05,
          thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
      }
      sleep(1)
    }
  }

  private func setLoop() {
    // The transport can be left hidden (a stray flick, remembered across
    // launches); then its controls sit below the screen and can't be tapped.
    if app.buttons["Show controls"].exists {
      app.buttons["Show controls"].tap()
      sleep(1)
      log("showed the hidden controls")
    }
    // The mode is a popup (compact) or a segmented button (wide).
    let loopSeg = app.buttons["Loop"]
    if loopSeg.exists {
      loopSeg.tap()
    } else {
      let pill = app.staticTexts.matching(beginning("Play once")).firstMatch
      if pill.exists {
        pill.tap()
        let item = app.descendants(matching: .any).matching(beginning("Loop")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
      }
    }
    if section != "All" {
      let chip = app.staticTexts[section]
      if chip.exists { chip.tap() }
    }
    log("mode set; section \(section)")
  }

  private var playButton: XCUIElement { app.buttons["Play"] }
  private var pauseButton: XCUIElement {
    app.buttons.matching(NSPredicate(format: "label IN {'Pause', 'Stop'}")).firstMatch
  }

  /// Route only: AirPlay receiver selected, and the app says so.
  func testPickReceiver() {
    openPiece()
    pickReceiver()
  }

  /// Loops a section on the receiver for MINUTES, logging the transport once
  /// every 10s, then stops (Stop is when the app writes its trace). Compare
  /// the receiver's log for gaps against the `[harness]` lines' times.
  func testLoopOnAirPlay() {
    openPiece()
    pickReceiver()
    setLoop()
    XCTAssertTrue(playButton.waitForExistence(timeout: 5))
    playButton.tap()
    log("PLAY")
    sleep(1)
    turnVolumeUp()
    let end = Date().addingTimeInterval(minutes * 60)
    var lastState = ""
    while Date() < end {
      sleep(10)
      let state = pauseButton.exists ? "playing" : (playButton.exists ? "stopped" : "?")
      let snack = app.buttons["Choose speaker"].exists ? " SNACKBAR(Choose speaker)" : ""
      let line = "\(state)\(snack) route=\(outputButton.label)"
      if line != lastState { log("state " + line) }
      lastState = line
      if state == "stopped" && snack.isEmpty {
        log("playback stopped on its own; pressing Play again")
        playButton.tap()
      }
    }
    if pauseButton.exists { pauseButton.tap() }
    log("STOP")
    sleep(3)
  }

  /// Leaves the app open on the piece, on the receiver, so a run can be
  /// started after the receiver has been away (stale-speaker test): play
  /// once, wait, report what the transport did.
  func testPlayAfterReceiverRestart() {
    openPiece()
    let route = outputButton.label
    log("route at start: \(route)")
    XCTAssertTrue(playButton.waitForExistence(timeout: 5))
    playButton.tap()
    log("PLAY")
    for _ in 0..<6 {
      sleep(5)
      let snack = app.buttons["Choose speaker"].exists
      log("state \(pauseButton.exists ? "playing" : "stopped") snackbar=\(snack) route=\(outputButton.label)")
    }
    if pauseButton.exists { pauseButton.tap() }
    log("STOP")
    sleep(3)
  }
}
