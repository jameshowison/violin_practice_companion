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
///   REPICK    "0" to keep the route when it already shows the receiver.
///             By default the test picks the phone's speaker, then the
///             receiver: a fresh connection, since a route that shows the
///             receiver can be dead (CLAUDE.md, "Audio on iOS" 6)
///   VOLUME_UP "0" to leave the volume alone (default: 16 presses up)
///   AFTER_STEPS set by the script for the long loop: the steps just made
///             the connection fresh, so keep it
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
    // Search for the title rather than scrolling: the library is long, and
    // swiping through it is slow and flaky (30 swipes weren't past "D").
    let search = app.textFields.firstMatch
    XCTAssertTrue(search.waitForExistence(timeout: 20), "no search field on the piece list")
    search.tap()
    search.typeText(piece)
    // Close the keyboard so it doesn't cover the row.
    let close = app.keyboards.buttons.matching(
      NSPredicate(format: "label IN %@", ["Done", "done", "Search", "search", "Return", "return"])
    ).firstMatch
    if close.waitForExistence(timeout: 2) { close.tap() }
    let row = app.staticTexts.matching(beginning(piece)).firstMatch
    // Flutter keeps off-screen rows in the tree with empty frames, so
    // "exists" isn't enough: the row must really be on screen.
    func onScreen() -> Bool {
      row.exists && row.frame.height > 40 && row.frame.maxY < app.frame.maxY - 80
    }
    _ = row.waitForExistence(timeout: 10)
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

  /// [fresh]: re-pick even when the route already shows the receiver. The
  /// later steps pass false, since step 2 has just made the connection.
  private func pickReceiver(fresh: Bool = true) {
    if env["SKIP_ROUTE"] != nil { return }  // simulator smoke run: no AirPlay there
    let repick = fresh && env["REPICK"] != "0"
    if outputButton.label.contains(receiver) && !repick {
      log("already on \(receiver)")
      return
    }
    outputButton.tap()
    let change = app.buttons.matching(beginning("Change")).firstMatch
    XCTAssertTrue(change.waitForExistence(timeout: 5))
    change.tap()
    // Away to the phone's own speaker and back, for a fresh connection.
    // The cure for a stale speaker (CLAUDE.md, "Audio on iOS" 6): the
    // receiver (the Mac's, 2026-11-22; the Pi's after ~1¾ h idle,
    // 2026-11-23) closed the session, the phone kept the route, and every
    // Play failed.
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
    let loopShown = app.descendants(matching: .any).matching(beginning("Loop")).firstMatch
    if loopSeg.exists {
      loopSeg.tap()
      log("mode: tapped the Loop segment")
    } else {
      let pill = app.staticTexts.matching(beginning("Play once")).firstMatch
      if pill.exists {
        pill.tap()
        XCTAssertTrue(loopShown.waitForExistence(timeout: 5), "no Loop item in the mode popup")
        loopShown.tap()
        log("mode: picked Loop from the popup")
      } else if loopShown.exists {
        log("mode: already Loop ('\(loopShown.label)')")
      } else {
        print("=== tree (no mode control)\n\(app.debugDescription)")
        XCTFail("found neither a Loop segment nor a Play once / Loop pill")
        return
      }
    }
    sleep(1)
    // App belief: the mode control now reads Loop.
    if !(loopSeg.exists && loopSeg.isSelected) && !loopShown.waitForExistence(timeout: 3) {
      print("=== tree (mode not Loop)\n\(app.debugDescription)")
      XCTFail("the mode control doesn't show Loop")
      return
    }
    if section != "All" {
      // Never skip a missing chip: the loop would then run over the whole
      // piece and look like a passing section loop (it did, 2026-11-23).
      let chip = app.descendants(matching: .any)
        .matching(NSPredicate(format: "label == %@", section)).firstMatch
      if !chip.waitForExistence(timeout: 10) {
        print("=== tree (no section chip \(section))\n\(app.debugDescription)")
        XCTFail("no section chip labelled \(section)")
        return
      }
      log("section chip: \(chip.elementType.rawValue) '\(chip.label)' at \(chip.frame)")
      chip.tap()
    }
    log("mode set; section \(section)")
  }

  private var playButton: XCUIElement { app.buttons["Play"] }
  private var pauseButton: XCUIElement {
    app.buttons.matching(NSPredicate(format: "label IN {'Pause', 'Stop'}")).firstMatch
  }

  // The steps. Each checks one more stage, in well under a minute, so a UI
  // quirk shows before a long recording rather than at its end.
  // `scripts/airplay_harness.sh` runs them in order and stops at the first
  // failure; each relaunches the app and redoes the stages before its own.

  /// Step 1: the piece opens (search, tap, the transport appears).
  func testStep1OpenPiece() {
    openPiece()
  }

  /// Step 2: the receiver is picked fresh, and the app says so.
  func testStep2PickReceiver() {
    openPiece()
    pickReceiver()
  }

  /// Step 3: Loop mode and the section, without playing.
  func testStep3SetLoop() {
    openPiece()
    pickReceiver(fresh: false)
    setLoop()
  }

  /// Step 4: ~15 s of play that stays playing on the receiver. The script
  /// checks the receiver got data meanwhile.
  func testStep4PlayBrief() {
    openPiece()
    pickReceiver(fresh: false)
    setLoop()
    startPlay()
    for _ in 0..<3 {
      sleep(5)
      let snack = app.buttons["Choose speaker"].exists
      let playing = pauseButton.exists
      log("state \(playing ? "playing" : "stopped") snackbar=\(snack) route=\(outputButton.label)")
      XCTAssertFalse(snack, "the app offered the speaker picker: the route is dead")
      XCTAssertTrue(playing, "playback stopped on its own")
      if snack || !playing { break }
    }
    if pauseButton.exists { pauseButton.tap() }
    log("STOP")
    sleep(3)
  }

  private func startPlay() {
    XCTAssertTrue(playButton.waitForExistence(timeout: 5), "no Play button")
    playButton.tap()
    log("PLAY")
    sleep(1)
    turnVolumeUp()
  }

  /// Loops a section on the receiver for MINUTES, logging the transport once
  /// every 10s, then stops (Stop is when the app writes its trace). Compare
  /// the receiver's log for gaps against the `[harness]` lines' times. Run
  /// after the steps (the script's --long), which made the connection fresh.
  func testLoopOnAirPlay() {
    openPiece()
    pickReceiver(fresh: env["AFTER_STEPS"] == nil)
    setLoop()
    startPlay()
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
