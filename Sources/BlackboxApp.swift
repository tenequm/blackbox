import AVFoundation
import Sparkle
import SwiftUI

@main
struct BlackboxApp: App {
  @NSApplicationDelegateAdaptor private var delegate: AppDelegate
  @State private var monitor = AudioMonitor()
  @State private var selectedTab: MainTab = .recordings
  private let updaterController = SPUStandardUpdaterController(
    startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

  init() {
    LogFile.rotateIfNeeded()
    Log.info(Log.app, "app", "launched")
    // Set monitor reference on delegate for graceful shutdown and startup.
    delegate.monitor = monitor
  }

  var body: some Scene {
    MenuBarExtra {
      MenuContent(monitor: monitor, updater: updaterController.updater, selectedTab: $selectedTab)
    } label: {
      // Menu bar images are rendered as template images by macOS - foregroundStyle
      // and symbolRenderingMode have no effect. State is conveyed via distinct SF Symbols.
      if monitor.permissionNeeded || monitor.errorMessage != nil {
        Image(systemName: "exclamationmark.triangle.fill")
      } else if monitor.isRecording {
        if let grace = monitor.graceCountdown {
          HStack(spacing: 4) {
            Image(systemName: "waveform.circle")
            Text(String(format: "0:%02d", Int(ceil(grace))))
              .monospacedDigit()
          }
        } else {
          HStack(spacing: 4) {
            Image(systemName: recordingWaveformIcon(level: monitor.audioLevel))
            if let elapsed = monitor.formattedElapsed {
              Text(elapsed)
                .monospacedDigit()
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
    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
      // Existing users who already granted screen recording don't need onboarding
      if CGPreflightScreenCaptureAccess() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
      }

      let willOnboard = !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")

      // Start monitoring AFTER the onboarding decision so the fallback
      // permission requests don't race with the onboarding UI.
      monitor?.startMonitoring(skipPermissionRequests: willOnboard)

      if willOnboard {
        showOnboarding()
      }
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
      Text("Screen Recording permission required")
        .foregroundStyle(.red)
      Button("Open System Settings") {
        NSWorkspace.shared.open(
          URL(
            string:
              "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        )
      }
      Button("Restart Blackbox") { restartApp() }
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

// MARK: - Helpers

/// Maps audio RMS level to a speaker SF Symbol.
/// Thresholds tuned for typical call audio captured via ScreenCaptureKit.
private func recordingWaveformIcon(level: Float) -> String {
  if level > 0.05 {
    return "speaker.wave.3"
  } else if level > 0.01 {
    return "speaker.wave.2"
  } else {
    return "speaker.wave.1"
  }
}

private func restartApp() {
  let url = Bundle.main.bundleURL
  // Terminate first, then relaunch. Without createsNewApplicationInstance,
  // open -a waits for the old process to exit before launching the new one.
  let task = Process()
  task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
  task.arguments = [url.path]
  try? task.run()
  NSApplication.shared.terminate(nil)
}
