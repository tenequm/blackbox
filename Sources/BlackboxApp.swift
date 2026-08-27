import AVFoundation
import CoreGraphics
import ServiceManagement
import Sparkle
import SwiftUI

@main
struct BlackboxApp: App {
  @NSApplicationDelegateAdaptor private var delegate: AppDelegate
  // Declared without an initial value: Xcode 27 reimplements @State as a macro that
  // rejects pairing a declaration initial value with assignment in an initializer.
  @State private var monitor: AudioMonitor
  @State private var transcriptionCoordinator: TranscriptionCoordinator
  /// Persisted, so the window reopens on the tab it was left on - and so the
  /// menu bar's Settings item can select the tab without reaching into the
  /// window's own state.
  @AppStorage(SettingsKeys.mainWindowTab) private var selectedTab: MainTab = .recordings
  private let updaterController = SPUStandardUpdaterController(
    startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

  init() {
    LogFile.rotateIfNeeded()
    Log.info(Log.app, "app", "launched")

    let coordinator = TranscriptionCoordinator()
    var dependencies = AudioMonitorDependencies.live
    // Not wired under `--ui-test-mode`. The hardware suite that `make test`
    // runs records real audio on a developer's machine, and this hook reads the
    // real auto-transcribe setting and the real Keychain key - so leaving it
    // wired sends those test recordings to a third party. The suite records
    // three of them, roughly 4s, 6s and 12s, all over the duration floor.
    if !BlackboxTestMode.isEnabled {
      dependencies.onRecordingSaved = { [weak coordinator] url in
        coordinator?.recordingFinished(recordingDirectory: url)
      }
    }
    let monitor = AudioMonitor(dependencies: dependencies)

    self.monitor = monitor
    self.transcriptionCoordinator = coordinator

    // Set references on delegate for graceful shutdown and startup.
    delegate.monitor = monitor
    delegate.transcriptionCoordinator = coordinator
  }

  /// The icon reacts to sound again, but every branch still draws at the same
  /// fixed width - and that part is load-bearing.
  ///
  /// The original picked between `waveform`, `waveform.mid` and `waveform.low`
  /// from `audioLevel`, published four times a second. Three glyphs of
  /// *different intrinsic widths* meant the status item re-laid-out at 4 Hz for
  /// the whole recording, which is the documented shape of an intermittent
  /// `_postWindowNeedsUpdateConstraints` crash - and under `LSUIElement` that
  /// crash is invisible: the icon simply disappears while the user believes the
  /// call is still being captured.
  ///
  /// So the level drives `scale` and opacity on ONE glyph inside a fixed frame.
  /// Same liveness, nothing re-measures.
  @ViewBuilder private var menuBarLabel: some View {
    let iconWidth: CGFloat = 16
    if monitor.isRecording {
      HStack(spacing: 4) {
        // Recording state wins the icon even when there is an error. A benign,
        // self-healing status like "Display slept - resuming recording..."
        // used to replace the glyph with a bare warning triangle for ten
        // seconds while capture continued perfectly well, which reads as "my
        // recording just died".
        Image(
          systemName: monitor.errorMessage != nil ? "waveform.badge.exclamationmark" : "waveform"
        )
        .symbolEffect(
          .variableColor,
          isActive: monitor.errorMessage == nil
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        .opacity(Self.levelOpacity(monitor.audioLevel))
        .animation(
          NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? nil : .easeOut(duration: 0.15),
          value: monitor.audioLevel
        )
        .frame(width: iconWidth)
        if let grace = monitor.graceCountdown {
          Text(Self.countdownText(grace))
            .monospacedDigit()
            .frame(minWidth: 32, alignment: .leading)
        } else if let elapsed = monitor.formattedElapsed {
          // `minWidth`, not a hard `width`: the old fixed 38pt clipped
          // "1:02:33" exactly when a user most wants to know how long they have
          // been recording, and clipped far sooner at accessibility text sizes.
          Text(elapsed)
            .monospacedDigit()
            .frame(minWidth: 38, alignment: .leading)
        }
      }
      .accessibilityLabel(accessibilityStatus)
      .help(accessibilityStatus)
    } else if monitor.isSaving {
      Image(systemName: "waveform.circle")
        .symbolEffect(
          .pulse, isActive: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        .frame(width: iconWidth)
        .accessibilityLabel("Blackbox - saving recording")
        .help("Saving recording")
    } else if monitor.permissionNeeded || monitor.errorMessage != nil {
      Image(systemName: "exclamationmark.triangle.fill")
        .frame(width: iconWidth)
        .accessibilityLabel(accessibilityStatus)
        .help(accessibilityStatus)
    } else {
      Image(systemName: "waveform.circle.fill")
        .frame(width: iconWidth)
        .accessibilityLabel("Blackbox - idle")
        .help("Blackbox - not recording")
    }
  }

  /// The menu bar item's whole meaning is its glyph, so it needs a name.
  private var accessibilityStatus: String {
    if monitor.permissionNeeded {
      return "Blackbox - screen recording permission required"
    }
    if monitor.isRecording {
      let app = monitor.currentAppName ?? "audio"
      let elapsed = monitor.formattedElapsed.map { ", \($0) elapsed" } ?? ""
      if let error = monitor.errorMessage {
        return "Blackbox - recording \(app)\(elapsed). \(error)"
      }
      return "Blackbox - recording \(app)\(elapsed)"
    }
    if let error = monitor.errorMessage { return "Blackbox - \(error)" }
    return "Blackbox - idle"
  }

  /// Maps the published RMS level onto an opacity the eye reads as "sound is
  /// happening". Never reaches zero: a silent moment in a call must still look
  /// like a running recording, not like a stopped one.
  ///
  /// The curve is deliberately steep at the bottom, because speech at a normal
  /// level sits near 0.02-0.05 RMS and a linear map would barely move.
  nonisolated static func levelOpacity(_ level: Float) -> Double {
    let normalized = min(1, max(0, Double(level) / 0.08))
    return 0.55 + 0.45 * sqrt(normalized)
  }

  /// Rolls over correctly at the top of the range. The old
  /// `String(format: "0:%02d", …)` hardcoded the minutes digit, so the maximum
  /// grace period of 60s rendered as "0:60".
  static func countdownText(_ remaining: TimeInterval) -> String {
    let total = max(0, Int(ceil(remaining)))
    return String(format: "%d:%02d", total / 60, total % 60)
  }

  /// The window may not be open yet, so the tab is selected first and the
  /// window asked for second.
  @MainActor private func openSettingsTab() {
    selectedTab = .settings
    NSApplication.shared.activate()
    NotificationCenter.default.post(name: RecordingHUD.openMainWindowNotification, object: nil)
  }

  var body: some Scene {
    MenuBarExtra {
      MenuContent(monitor: monitor, updater: updaterController.updater)
    } label: {
      menuBarLabel
      // Zero-sized, and here rather than in the window because the status item
      // is the one view alive for the whole process. `openWindow` exists only
      // in a view's environment, and the delegate - which owns the toast-click
      // observer - has no environment of its own.
      OpenWindowRegistrar(delegate: delegate)
    }
    .menuBarExtraStyle(.menu)

    Window("Blackbox", id: "main") {
      MainWindowView(selectedTab: $selectedTab)
        .environment(transcriptionCoordinator)
        // Settings can move the whole recordings folder, so it needs to know
        // whether a recording is live.
        .environment(monitor)
    }
    .defaultSize(width: 900, height: 600)
    .defaultPosition(.center)
    // A background recorder should not shove its window in front of the user at
    // every login just because it happened to be open at quit.
    .restorationBehavior(.disabled)
    .commands {
      // Menu-item shortcuts on a `MenuBarExtra` only fire while that menu is
      // open, so the app had no working Cmd+, from the window a user was
      // actually looking at, and no Cmd+W, Cmd+Delete or Cmd+F at all.
      CommandGroup(replacing: .appInfo) {
        Button("About Blackbox") {
          NSApplication.shared.orderFrontStandardAboutPanel(nil)
        }
      }
      CommandGroup(after: .appInfo) {
        Button("Check for Updates…") {
          NSApplication.shared.activate()
          updaterController.updater.checkForUpdates()
        }
      }
      // Wired by hand: with Settings back as a tab there is no `Settings` scene
      // to provide this for free. Replacing `.appSettings` keeps the item where
      // a Mac user looks for it, and keeps the shortcut working.
      CommandGroup(replacing: .appSettings) {
        Button("Settings…") { openSettingsTab() }
          .keyboardShortcut(",", modifiers: .command)
      }
      CommandMenu("Recording") {
        Button("Record Now") { monitor.startManualRecording() }
          .keyboardShortcut("r")
          .disabled(monitor.isRecording)
        Button("Stop Recording") {
          if monitor.isManualRecording {
            monitor.stopManualRecording()
          } else {
            monitor.forceStopAutoRecording()
          }
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(!monitor.isRecording)
      }
    }

  }

  final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var monitor: AudioMonitor?
    var transcriptionCoordinator: TranscriptionCoordinator?
    /// Set by the app body so the toast can reach the same window-opening path
    /// the menu uses.
    var openMainWindow: (() -> Void)?
    private var onboardingWindow: NSWindow?
    private var testController: BlackboxTestController?
    private var openWindowObserver: (any NSObjectProtocol)?

    func applicationDidFinishLaunching(_ notification: Notification) {
      installCrashHandler()
      observeToastClicks()
      if !BlackboxTestMode.isEnabled {
        launchWatchdog()
      }

      if BlackboxTestMode.isEnabled {
        monitor?.startMonitoring(skipPermissionRequests: true)
        if let monitor {
          let controller = BlackboxTestController(monitor: monitor)
          controller.start()
          testController = controller
        }
        return
      }

      // CGPreflightScreenCaptureAccess is the source of truth on every launch.
      // If the user denies on first run or revokes between sessions, onboarding
      // re-appears.
      let willOnboard = !CGPreflightScreenCaptureAccess()

      // Start monitoring AFTER the onboarding decision so the fallback
      // permission requests don't race with the onboarding UI.
      monitor?.startMonitoring(skipPermissionRequests: willOnboard)
      // Pick up anything a previous session left mid-flight.
      transcriptionCoordinator?.resumePendingJobs()
      // A killed echo-cancellation run cannot clean up after itself.
      let saveDirectory =
        BlackboxTestMode.saveDirectoryOverride
        ?? URL(
          fileURLWithPath: UserDefaults.standard.string(forKey: SettingsKeys.saveDirectoryPath)
            ?? defaultSaveDirectoryPath)
      Task.detached { AECProcessor.sweepPartialFiles(in: saveDirectory) }

      if willOnboard {
        showOnboarding()
      } else {
        // `applicationShouldHandleReopen` only fires when the app was already
        // running, so a cold launch from Spotlight or `open -a` reached nothing
        // and the window never appeared.
        openMainWindowIfThisLaunchWasTheUser()
      }
    }

    /// "The user launched me" and "launchd launched me at login" are the same
    /// launch as far as this process can tell. Measured on this app: a
    /// foreground `open`, a background `open -g` and a login launch all arrive
    /// with `NSApplicationLaunchIsDefaultLaunchKey` true and the same
    /// `application.<bundle-id>.<n>.<n>` launchd label; `isActive` is false in
    /// every case, and a windowless `LSUIElement` app is never made active, so
    /// waiting for an activation waits forever.
    ///
    /// What does separate them is *when*. A login launch happens in the first
    /// moments of a session; a user launching the app happens whenever they
    /// felt like it. So the window is suppressed only for a launch that is both
    /// a login item's and inside that opening window - opening one at every
    /// login is precisely what `.restorationBehavior(.disabled)` on the scene
    /// exists to prevent. With the switch off, nothing is suppressed at all.
    private func openMainWindowIfThisLaunchWasTheUser() {
      if SMAppService.mainApp.status == .enabled, let age = Self.secondsSinceLogin(),
        age < Self.loginLaunchWindow
      {
        Log.info(
          Log.app, "app",
          "not opening the window: launched \(Int(age))s into this login session, as a login item")
        return
      }
      openMainWindowAfterSceneSetup()
    }

    /// Generous, because a login item can be started well after the session
    /// begins on a busy machine, and the cost of being wrong in this direction
    /// is one missing window on a launch the user can simply repeat.
    private static let loginLaunchWindow: TimeInterval = 120

    /// Age of this login session, read from the console record in `utmpx`. Nil
    /// when there is no such record, which is treated as "not a login launch"
    /// rather than guessed at.
    private static func secondsSinceLogin() -> TimeInterval? {
      setutxent()
      defer { endutxent() }
      var loggedInAt: time_t?
      while let entry = getutxent() {
        let record = entry.pointee
        guard record.ut_type == USER_PROCESS else { continue }
        var line = record.ut_line
        let name = withUnsafeBytes(of: &line) { raw -> String in
          String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        guard name == "console" else { continue }
        loggedInAt = record.ut_tv.tv_sec
      }
      guard let loggedInAt else { return nil }
      return Date().timeIntervalSince1970 - TimeInterval(loggedInAt)
    }

    /// Deferred one turn because the scene and its `OpenWindowRegistrar` are
    /// not wired until after `applicationDidFinishLaunching` returns.
    private func openMainWindowAfterSceneSetup() {
      DispatchQueue.main.async { [weak self] in
        Log.info(Log.app, "app", "opening the main window for this launch")
        self?.openMainWindow?()
        NSApplication.shared.activate()
      }
    }

    /// Lives on the delegate, which is alive for the whole process.
    ///
    /// This observer used to hang off `.onReceive` on the Quit button inside
    /// `MenuContent`. With `.menuBarExtraStyle(.menu)` that content is only
    /// materialized while the menu is open - and the "Recording Saved" toast
    /// fires when a recording ends, which is precisely when the menu is closed.
    /// So the app's most discoverable affordance, "I just recorded something,
    /// take me to it", was a no-op in normal use.
    private func observeToastClicks() {
      openWindowObserver = NotificationCenter.default.addObserver(
        forName: RecordingHUD.openMainWindowNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.openMainWindow?()
          NSApplication.shared.activate()
        }
      }
    }

    private func launchWatchdog() {
      guard let url = Bundle.main.executableURL else { return }
      let watchdogURL = url.deletingLastPathComponent()
        .appendingPathComponent("BlackboxWatchdog")
      guard FileManager.default.fileExists(atPath: watchdogURL.path) else { return }

      let process = Process()
      process.executableURL = watchdogURL
      process.arguments = [String(ProcessInfo.processInfo.processIdentifier)]
      try? process.run()
    }

    private func installCrashHandler() {
      guard !BlackboxTestMode.isEnabled else {
        NSSetUncaughtExceptionHandler(uncaughtExceptionHandler)
        return
      }

      // Read previous state BEFORE marking current session as running
      let previousSessionCrashed = UserDefaults.standard.bool(forKey: "processRunning")
      UserDefaults.standard.set(true, forKey: "processRunning")

      if previousSessionCrashed {
        Log.error(Log.app, "crash", "Previous session did not exit cleanly")
        Task {
          try? await Task.sleep(for: .seconds(2))
          monitor?.setError("Previous session crashed unexpectedly")
        }
      }

      NSSetUncaughtExceptionHandler(uncaughtExceptionHandler)
    }

    /// Also reachable from the menu, not only on a failed preflight at launch.
    /// A user who dismissed the welcome window with the X - the reflex for an
    /// unexpected window - could never see it again, and it is the only place
    /// the app explains that it does not record your screen.
    func showOnboarding() {
      Log.info(Log.app, "app", "opening the setup assistant")
      if let existing = onboardingWindow {
        existing.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
        return
      }
      let onboarding = OnboardingView(onComplete: { [weak self] in
        // Close first, drop the reference on the next turn. Releasing the
        // window inside a SwiftUI action hosted by that very window's content
        // view deallocates the hosting view mid-unwind.
        guard let window = self?.onboardingWindow else { return }
        self?.isDismissingOnboarding = true
        window.close()
        DispatchQueue.main.async {
          self?.onboardingWindow = nil
          self?.isDismissingOnboarding = false
        }
      })
      let hosting = NSHostingView(rootView: onboarding)
      let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: OnboardingView.windowSize),
        styleMask: [.titled, .closable],
        backing: .buffered, defer: false
      )
      window.isReleasedWhenClosed = false
      window.delegate = self
      window.title = "Welcome to Blackbox"
      window.contentView = hosting
      window.center()
      window.makeKeyAndOrderFront(nil)
      NSApplication.shared.activate()
      onboardingWindow = window
    }

    private var isDismissingOnboarding = false

    /// Launching an app that is already running - Spotlight, `open -a`, the
    /// Dock if there were one - sends this instead of starting a second
    /// process. Without it the gesture did nothing at all under `LSUIElement`,
    /// because there is no Dock icon to bounce and no window to raise.
    ///
    /// Distinct from `.restorationBehavior(.disabled)` on the window scene,
    /// which is about macOS reopening the window by itself at login. This only
    /// fires when the user explicitly asks for the app.
    func applicationShouldHandleReopen(
      _ sender: NSApplication, hasVisibleWindows: Bool
    ) -> Bool {
      guard !BlackboxTestMode.isEnabled else { return true }
      if !hasVisibleWindows {
        openMainWindow?()
      }
      NSApplication.shared.activate()
      return true
    }

    func windowWillClose(_ notification: Notification) {
      guard !isDismissingOnboarding,
        let window = notification.object as? NSWindow, window === onboardingWindow
      else { return }
      onboardingWindow = nil
    }

    /// Instance state, not a local. The menu bar stays fully interactive during
    /// the `.terminateLater` window, so a second quit - the menu item pressed
    /// twice, a logout Apple Event, Sparkle - re-enters this method. A local
    /// flag gives each invocation its own, and both can then call
    /// `reply(toApplicationShouldTerminate:)`, which is unbalanced and
    /// undefined.
    private var hasRepliedToTerminate = false
    private var isTerminating = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
      guard !isTerminating else { return .terminateLater }
      isTerminating = true
      testController?.stop()
      // Precise replacement for the recording gate that used to defer jobs at
      // quit as a side effect. One synchronous bool on the main actor, so it
      // cannot extend the 8s budget - and unlike the gate, it fires on quit and
      // only on quit.
      transcriptionCoordinator?.suspendNewJobs()
      guard let monitor else {
        Log.info(Log.app, "app", "terminating (no monitor)")
        if !BlackboxTestMode.isEnabled {
          UserDefaults.standard.set(false, forKey: "processRunning")
        }
        return .terminateNow
      }
      Log.info(Log.app, "app", "terminating, cleaning up recordings")
      // No Dock icon to carry a "quitting" state and the menu has already
      // closed, so a recording that takes seconds to finalize looks like a
      // hang. The user's next move is Force Quit, which is the one thing that
      // damages the file being written.
      if monitor.isRecording || monitor.isSaving {
        monitor.showFinalizingToast()
      }
      let timeoutTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(8))
        guard !Task.isCancelled, self?.hasRepliedToTerminate == false else { return }
        self?.hasRepliedToTerminate = true
        Log.error(Log.app, "app", "termination cleanup timed out after 8s")
        self?.markCleanExit()
        NSApplication.shared.reply(toApplicationShouldTerminate: true)
      }
      Task { [weak self] in
        await monitor.stopMonitoring()
        timeoutTask.cancel()
        guard self?.hasRepliedToTerminate == false else { return }
        self?.hasRepliedToTerminate = true
        self?.markCleanExit()
        NSApplication.shared.reply(toApplicationShouldTerminate: true)
      }
      return .terminateLater
    }

    /// Written from the reply paths rather than on entry. Clearing it first
    /// meant a crash *during* the eight-second cleanup - the riskiest moment in
    /// the process - was recorded as a clean exit.
    private func markCleanExit() {
      guard !BlackboxTestMode.isEnabled else { return }
      UserDefaults.standard.set(false, forKey: "processRunning")
    }
  }
}

// MARK: - Window Opener

/// Hands the delegate a way to open the main window. Draws nothing.
private struct OpenWindowRegistrar: View {
  let delegate: BlackboxApp.AppDelegate
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .onAppear {
        delegate.openMainWindow = { openWindow(id: "main") }
      }
  }
}

// MARK: - Menu

struct MenuContent: View {
  let monitor: AudioMonitor
  let updater: SPUUpdater
  @Environment(\.openWindow) private var openWindow
  /// Written straight to defaults; `AudioMonitor` picks it up on its next
  /// settings pass, the same way the Settings tab's toggle works.
  @AppStorage(SettingsKeys.autoRecord) private var autoRecord = true
  @AppStorage(SettingsKeys.saveDirectoryPath) private var saveDirectoryPath =
    defaultSaveDirectoryPath
  /// `CGRequestScreenCaptureAccess` prompts once per process and silently
  /// returns false thereafter, so the button has to stop offering to ask.
  @State private var hasRequestedScreenCapture = false
  @AppStorage(SettingsKeys.mainWindowTab) private var settingsTab: MainTab = .recordings

  var body: some View {
    // Primary action
    if monitor.isManualRecording {
      Button("Stop Recording") {
        monitor.stopManualRecording()
      }
    } else if monitor.isRecording {
      Button("Stop Recording") {
        monitor.forceStopAutoRecording()
      }
    } else {
      Button("Record Now") {
        monitor.startManualRecording()
      }
      .keyboardShortcut("r")
    }

    // The realistic case is a call the user does not want recorded, decided
    // seconds before it starts. Without this the options were: open the window,
    // find Settings, toggle, remember to toggle back - or quit the app and
    // forget to relaunch it, silently losing every recording afterwards.
    Toggle("Record Calls Automatically", isOn: $autoRecord)

    Divider()

    // Status
    if monitor.permissionNeeded {
      Text("Screen & System Audio Recording permission required")
        .foregroundStyle(.red)
      // Same rule as the microphone branch below: ask where asking works, and
      // only send the user to System Settings when it does not. A user who has
      // never been prompted is the common case here, because the preflight poll
      // sets this flag before any recording is attempted.
      if CGPreflightScreenCaptureAccess() == false, !hasRequestedScreenCapture {
        Button("Grant Screen Recording Access") {
          hasRequestedScreenCapture = true
          CGRequestScreenCaptureAccess()
        }
      } else {
        Button("Open System Settings…") {
          openPrivacySettings(pane: .screenCapture)
        }
      }
    } else if monitor.micPermissionNeeded {
      // Both recording paths use the microphone, not just manual ones - a user
      // who read the old wording concluded their automatic call recordings were
      // fine without it, and they are not: they would be missing their own
      // voice.
      Text("Microphone permission needed - recordings will not include your voice")
        .foregroundStyle(.orange)
      // `requestAccess` silently does nothing once the user has denied, so the
      // button offered to fix the problem did nothing at all and got clicked
      // repeatedly. Prompt only where a prompt is possible; otherwise send them
      // where the switch actually is.
      if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
        Button("Grant Microphone Access") {
          Task { await AVCaptureDevice.requestAccess(for: .audio) }
        }
      } else {
        Button("Open System Settings…") {
          openPrivacySettings(pane: .microphone)
        }
      }
    } else if let errorMsg = monitor.errorMessage {
      Text(errorMsg)
        .foregroundStyle(.red)
    } else if monitor.isRecording, let appName = monitor.currentAppName {
      if let grace = monitor.graceCountdown {
        Text(
          "\(appName) - \(monitor.formattedElapsed ?? "0:00") (ending in \(BlackboxApp.countdownText(grace)))"
        )
      } else {
        Text("Recording \(appName) - \(monitor.formattedElapsed ?? "0:00")")
      }
    } else if monitor.isSaving {
      Text("Saving recording...")
        .foregroundStyle(.secondary)
    }

    Divider()

    Button("Open Blackbox") {
      // Deliberately does not force the tab: reopening from the menu used to
      // discard whichever tab the user had been on.
      openWindow(id: "main")
      NSApplication.shared.activate()
    }
    .keyboardShortcut("o")

    // The app's output is files on disk, and there was no one-click route to
    // them from the menu.
    Button("Reveal Recordings in Finder") {
      NSWorkspace.shared.selectFile(
        monitor.lastSavedRecordingURL?.path,
        inFileViewerRootedAtPath: saveDirectoryPath)
    }

    Divider()

    // The standard panel, not a window scene: the `Window(id: "about")` this
    // used to open was removed when Settings moved to its own scene, and under
    // LSUIElement the menu bar is the About users actually reach.
    Button("About Blackbox") {
      NSApplication.shared.activate()
      NSApplication.shared.orderFrontStandardAboutPanel(nil)
    }

    Button("Check for Updates…") {
      NSApplication.shared.activate()
      updater.checkForUpdates()
    }

    Button("Setup Assistant…") {
      guard let delegate = NSApplication.shared.delegate as? BlackboxApp.AppDelegate else {
        Log.error(Log.app, "app", "setup assistant: app delegate is not BlackboxApp.AppDelegate")
        return
      }
      delegate.showOnboarding()
    }

    Button("Report a Bug") {
      NSWorkspace.shared.open(URL(string: "https://github.com/tenequm/blackbox/issues/new")!)
    }

    Button("Settings…") {
      settingsTab = .settings
      NSApplication.shared.activate()
      NotificationCenter.default.post(name: RecordingHUD.openMainWindowNotification, object: nil)
    }
    .keyboardShortcut(",", modifiers: .command)

    Divider()

    Button(monitor.isRecording ? "Quit (recording will be saved)" : "Quit Blackbox") {
      NSApplication.shared.terminate(nil)
    }
    .keyboardShortcut("q")
  }

}

// MARK: - About

// MARK: - Uncaught Exception Handler

/// Must be nonisolated and at file scope - NSSetUncaughtExceptionHandler fires on whatever
/// thread the exception was thrown on. A @MainActor-inferred closure would SIGTRAP when
/// called from a background thread due to Swift 6 runtime isolation checks.
nonisolated private func uncaughtExceptionHandler(_ exception: NSException) {
  Log.error(
    Log.app, "crash",
    "Uncaught exception: \(exception.name.rawValue) - \(exception.reason ?? "Unknown")")
}

// MARK: - Helpers

/// Maps audio RMS level to a waveform SF Symbol.
/// Thresholds tuned for typical call audio.
/// Buckets by dBFS, not linear RMS: conversational mic speech sits around
