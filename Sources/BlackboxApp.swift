import AVFoundation
import CoreGraphics
import Sparkle
import SwiftUI

@main
struct BlackboxApp: App {
  @NSApplicationDelegateAdaptor private var delegate: AppDelegate
  // Declared without an initial value: Xcode 27 reimplements @State as a macro that
  // rejects pairing a declaration initial value with assignment in an initializer.
  @State private var monitor: AudioMonitor
  @State private var transcriptionCoordinator: TranscriptionCoordinator
  @State private var selectedTab: MainTab = .recordings
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
    // wired sends those test recordings to a third party. They are 4s and ~12s,
    // both over the duration floor.
    if !BlackboxTestMode.isEnabled {
      dependencies.onRecordingSaved = { [weak coordinator] url in
        coordinator?.recordingFinished(audioFileURL: url)
      }
    }
    let monitor = AudioMonitor(dependencies: dependencies)
    coordinator.isRecordingActive = { [weak monitor] in monitor?.isRecording ?? false }

    self.monitor = monitor
    self.transcriptionCoordinator = coordinator

    // Set references on delegate for graceful shutdown and startup.
    delegate.monitor = monitor
    delegate.transcriptionCoordinator = coordinator
  }

  var body: some Scene {
    MenuBarExtra {
      MenuContent(monitor: monitor, updater: updaterController.updater, selectedTab: $selectedTab)
    } label: {
      if monitor.permissionNeeded || monitor.errorMessage != nil {
        Image(systemName: "exclamationmark.triangle.fill")
      } else if monitor.isRecording {
        if let grace = monitor.graceCountdown {
          HStack(spacing: 4) {
            Image(systemName: "waveform.circle")
            Text(String(format: "0:%02d", Int(ceil(grace))))
              .frame(width: 32, alignment: .leading)
          }
        } else {
          HStack(spacing: 4) {
            Image(systemName: recordingWaveformIcon(level: monitor.audioLevel))
            if let elapsed = monitor.formattedElapsed {
              Text(elapsed)
                .frame(width: 38, alignment: .leading)
            }
          }
        }
      } else {
        Image(systemName: "waveform.circle.fill")
      }
    }
    .menuBarExtraStyle(.menu)

    Window("Blackbox", id: "main") {
      MainWindowView(selectedTab: $selectedTab)
        .environment(transcriptionCoordinator)
    }
    .defaultSize(width: 700, height: 500)
    .defaultPosition(.center)

    Window("About Blackbox", id: "about") {
      AboutView()
    }
    .windowResizability(.contentSize)

  }

  final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var monitor: AudioMonitor?
    var transcriptionCoordinator: TranscriptionCoordinator?
    private var onboardingWindow: NSWindow?
    private var testController: BlackboxTestController?

    func applicationDidFinishLaunching(_ notification: Notification) {
      installCrashHandler()
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
      // re-appears. The `hasCompletedOnboarding` UserDefaults key is now only
      // written by `windowWillClose` as an X-button courtesy flag; it is never
      // read here because preflight alone gives the correct answer.
      let willOnboard = !CGPreflightScreenCaptureAccess()

      // Start monitoring AFTER the onboarding decision so the fallback
      // permission requests don't race with the onboarding UI.
      monitor?.startMonitoring(skipPermissionRequests: willOnboard)
      // Pick up anything a previous session left mid-flight.
      transcriptionCoordinator?.resumePendingJobs()

      if willOnboard {
        showOnboarding()
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

    private func showOnboarding() {
      let onboarding = OnboardingView(onComplete: { [weak self] in
        let window = self?.onboardingWindow
        self?.onboardingWindow = nil  // Clear first so windowWillClose guard fails
        window?.close()
      })
      let hosting = NSHostingView(rootView: onboarding)
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
        styleMask: [.titled, .closable],
        backing: .buffered, defer: false
      )
      window.isReleasedWhenClosed = false
      window.delegate = self
      window.title = "Welcome to Blackbox"
      window.contentView = hosting
      window.center()
      window.makeKeyAndOrderFront(nil)
      NSApplication.shared.activate(ignoringOtherApps: true)
      onboardingWindow = window
    }

    func windowWillClose(_ notification: Notification) {
      guard let window = notification.object as? NSWindow, window === onboardingWindow else {
        return
      }
      // User closed onboarding via X button - mark complete so it doesn't nag
      UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
      onboardingWindow = nil
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
      testController?.stop()
      if !BlackboxTestMode.isEnabled {
        UserDefaults.standard.set(false, forKey: "processRunning")
      }
      guard let monitor else {
        Log.info(Log.app, "app", "terminating (no monitor)")
        return .terminateNow
      }
      Log.info(Log.app, "app", "terminating, cleaning up recordings")
      var hasReplied = false
      let timeoutTask = Task {
        try? await Task.sleep(for: .seconds(8))
        guard !Task.isCancelled, !hasReplied else { return }
        hasReplied = true
        Log.error(Log.app, "app", "termination cleanup timed out after 8s")
        NSApplication.shared.reply(toApplicationShouldTerminate: true)
      }
      Task {
        await monitor.stopMonitoring()
        timeoutTask.cancel()
        guard !hasReplied else { return }
        hasReplied = true
        NSApplication.shared.reply(toApplicationShouldTerminate: true)
      }
      return .terminateLater
    }
  }
}

// MARK: - Menu

struct MenuContent: View {
  let monitor: AudioMonitor
  let updater: SPUUpdater
  @Binding var selectedTab: MainTab
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openWindow) private var openWindow

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
    }

    Divider()

    // Status
    if monitor.permissionNeeded {
      Text("Screen & System Audio Recording permission required")
        .foregroundStyle(.red)
      Button("Open System Settings") {
        NSWorkspace.shared.open(
          URL(
            string:
              "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
          )!
        )
      }
    } else if monitor.micPermissionNeeded {
      Text("Microphone permission needed for manual recordings")
        .foregroundStyle(.orange)
      Button("Grant Microphone Access") {
        Task { await AVCaptureDevice.requestAccess(for: .audio) }
      }
    } else if let errorMsg = monitor.errorMessage {
      Text(errorMsg)
        .foregroundStyle(.red)
    } else if monitor.isRecording, let appName = monitor.currentAppName {
      if let grace = monitor.graceCountdown {
        Text("\(appName) - \(monitor.formattedElapsed ?? "0:00") (ending in \(Int(grace))s)")
      } else {
        Text("Recording \(appName) - \(monitor.formattedElapsed ?? "0:00")")
      }
    } else if monitor.isSaving {
      Text("Saving recording...")
        .foregroundStyle(.secondary)
    }

    Divider()

    Button("Open Blackbox") {
      selectedTab = .recordings
      openWindow(id: "main")
      NSApplication.shared.activate(ignoringOtherApps: true)
    }
    .keyboardShortcut("o")

    Divider()

    Button("About Blackbox") {
      openWindow(id: "about")
      NSApplication.shared.activate(ignoringOtherApps: true)
    }

    Button("Check for Updates...") {
      updater.checkForUpdates()
    }

    Button("Report a Bug") {
      NSWorkspace.shared.open(URL(string: "https://github.com/tenequm/blackbox/issues/new")!)
    }

    Button("Settings...") {
      selectedTab = .settings
      openWindow(id: "main")
      NSApplication.shared.activate(ignoringOtherApps: true)
    }
    .keyboardShortcut(",", modifiers: .command)

    Divider()

    Button(monitor.isRecording ? "Quit (recording will be saved)" : "Quit Blackbox") {
      NSApplication.shared.terminate(nil)
    }
    .keyboardShortcut("q")
    .onReceive(
      NotificationCenter.default.publisher(for: RecordingHUD.openMainWindowNotification)
    ) { _ in
      selectedTab = .recordings
      openWindow(id: "main")
      NSApplication.shared.activate(ignoringOtherApps: true)
    }
  }

}

// MARK: - About

private struct AboutView: View {
  var body: some View {
    VStack(spacing: 12) {
      Image(nsImage: NSApplication.shared.applicationIconImage)
        .resizable()
        .frame(width: 64, height: 64)
      Text("Blackbox")
        .font(.title2.bold())
      Text(
        "Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")"
      )
      .foregroundStyle(.secondary)
      Text("Auto-records your call audio")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(24)
    .frame(width: 260)
  }
}

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
/// -36 dBFS RMS, which a linear 0.05 threshold (-26 dBFS) never registers.
func recordingWaveformIcon(level: Float) -> String {
  let dbfs = level > 0 ? 20 * log10(level) : -Float.infinity
  if dbfs > -30 {
    return "waveform"
  } else if dbfs > -45 {
    return "waveform.mid"
  } else {
    return "waveform.low"
  }
}
