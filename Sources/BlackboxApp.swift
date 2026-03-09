import AVFoundation
import Sparkle
import SwiftUI

@main
struct BlackboxApp: App {
  @NSApplicationDelegateAdaptor private var delegate: AppDelegate
  @State private var monitor = AudioMonitor()
  private let updaterController = SPUStandardUpdaterController(
    startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

  init() {
    LogFile.rotateIfNeeded()
    Log.info(Log.app, "app", "launched")
    // Set monitor reference on delegate early for graceful shutdown.
    // @NSApplicationDelegateAdaptor sets the delegate before App.init runs.
    (NSApplication.shared.delegate as? AppDelegate)?.monitor = monitor
  }

  var body: some Scene {
    MenuBarExtra {
      MenuContent(monitor: monitor, updater: updaterController.updater)
    } label: {
      if monitor.permissionNeeded || monitor.micPermissionNeeded {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.yellow)
      } else if monitor.errorMessage != nil {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.yellow)
      } else if monitor.isPaused {
        Image(systemName: "pause.circle")
          .foregroundStyle(.secondary)
      } else if monitor.isRecording {
        Image(systemName: "waveform.circle.fill")
          .symbolRenderingMode(.palette)
          .foregroundStyle(.red, .primary)
      } else {
        Image(systemName: "waveform")
      }
    }
    .menuBarExtraStyle(.menu)

    Settings {
      SettingsView()
    }

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
      let timeoutTask = Task {
        try? await Task.sleep(for: .seconds(5))
        guard !Task.isCancelled else { return }
        NSApplication.shared.reply(toApplicationShouldTerminate: true)
      }
      Task {
        await monitor.stopMonitoring()
        timeoutTask.cancel()
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
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openSettings) private var openSettings
  @Environment(\.openWindow) private var openWindow

  var body: some View {
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
      Text("Microphone permission needed for full recording")
        .foregroundStyle(.orange)
      Button("Grant Microphone Access") {
        Task { await AVCaptureDevice.requestAccess(for: .audio) }
      }
    } else if let errorMsg = monitor.errorMessage {
      Text(errorMsg)
        .foregroundStyle(.red)
    } else if monitor.isPaused {
      Text("Monitoring paused")
        .foregroundStyle(.secondary)
    } else if let appName = monitor.currentAppName, let start = monitor.recordingStartTime {
      TimelineView(.periodic(from: .now, by: 1)) { context in
        let elapsed = context.date.timeIntervalSince(start)
        if let grace = monitor.graceCountdown {
          Text("\(appName) - \(formatElapsed(elapsed)) (ending in \(Int(grace))s)")
        } else {
          Text("Recording \(appName) - \(formatElapsed(elapsed))")
        }
      }
    } else if monitor.isSaving {
      Text("Saving recording...")
        .foregroundStyle(.secondary)
    } else {
      Text(idleStatusText)
        .foregroundStyle(.secondary)
    }

    Divider()

    // Recording controls
    if monitor.isManualRecording {
      Button("Stop Recording") {
        monitor.stopManualRecording()
      }
    } else if !monitor.isRecording {
      Button("Record System Audio") {
        monitor.startManualRecording()
      }
    }

    Button(monitor.isPaused ? "Resume Monitoring" : "Pause Monitoring") {
      monitor.togglePause()
    }

    Divider()

    // Recent recordings
    Menu("Recent Recordings") {
      ForEach(recentRecordings, id: \.absoluteString) { url in
        Button(url.lastPathComponent) {
          NSWorkspace.shared.activateFileViewerSelecting([url])
        }
      }
      if recentRecordings.isEmpty {
        Text("No recordings yet")
          .foregroundStyle(.secondary)
      }
    }

    Button("Open Recordings Folder") {
      let url = monitor.saveDirectory
      try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      NSWorkspace.shared.open(url)
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

    Button("Settings...") {
      openSettings()
      NSApplication.shared.activate(ignoringOtherApps: true)
    }
    .keyboardShortcut(",", modifiers: .command)

    Divider()

    Button(monitor.isRecording ? "Quit (recording will be saved)" : "Quit Blackbox") {
      NSApplication.shared.terminate(nil)
    }
    .keyboardShortcut("q")
  }

  // MARK: - Computed Properties

  private var idleStatusText: String {
    let running = NSWorkspace.shared.runningApplications
    let names = monitor.targetBundleIDs.compactMap { bid in
      running.first(where: { $0.bundleIdentifier == bid })?.localizedName
    }
    return names.isEmpty ? "No target apps running" : "Monitoring \(names.joined(separator: ", "))"
  }

  private var recentRecordings: [URL] {
    let dir = monitor.saveDirectory
    guard
      let files = try? FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
        options: .skipsHiddenFiles)
    else { return [] }
    return
      files
      .filter { $0.pathExtension == "m4a" }
      .sorted {
        let d1 =
          (try? $0.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? .distantPast
        let d2 =
          (try? $1.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? .distantPast
        return d1 > d2
      }
      .prefix(5)
      .map { $0 }
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

private func formatElapsed(_ interval: TimeInterval) -> String {
  let total = max(0, Int(interval))
  let h = total / 3600
  let m = (total % 3600) / 60
  let s = total % 60
  return h > 0
    ? String(format: "%d:%02d:%02d", h, m, s)
    : String(format: "%d:%02d", m, s)
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
