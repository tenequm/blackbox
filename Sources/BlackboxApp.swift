import SwiftUI

@main
struct BlackboxApp: App {
  @NSApplicationDelegateAdaptor private var delegate: AppDelegate
  @State private var monitor = AudioMonitor()

  init() {
    monitor.startMonitoring()
  }

  var body: some Scene {
    MenuBarExtra {
      MenuContent(monitor: monitor)
    } label: {
      if monitor.isRecording {
        Image(systemName: "waveform.circle.fill")
          .symbolRenderingMode(.palette)
          .foregroundStyle(.red, .primary)
      } else {
        Image(systemName: "waveform")
          .foregroundStyle(.secondary)
      }
    }
    .menuBarExtraStyle(.menu)

    Settings {
      SettingsView()
    }
  }

  final class AppDelegate: NSObject, NSApplicationDelegate {
    var monitor: AudioMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
      if !CGPreflightScreenCaptureAccess() {
        CGRequestScreenCaptureAccess()
      }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
      guard let monitor else { return .terminateNow }
      Task {
        await monitor.stopMonitoring()
        NSApplication.shared.reply(toApplicationShouldTerminate: true)
      }
      return .terminateLater
    }
  }
}

struct MenuContent: View {
  let monitor: AudioMonitor
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    Color.clear.frame(width: 0, height: 0)
      .onAppear {
        // Give AppDelegate a reference for graceful shutdown
        if let delegate = NSApplication.shared.delegate as? BlackboxApp.AppDelegate {
          delegate.monitor = monitor
        }
      }

    if monitor.permissionNeeded {
      Button("Screen Recording Permission Required") {
        NSWorkspace.shared.open(
          URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        )
      }
    } else if let appName = monitor.currentAppName, let start = monitor.recordingStartTime {
      TimelineView(.periodic(from: .now, by: 1)) { context in
        let elapsed = context.date.timeIntervalSince(start)
        let minutes = Int(elapsed) / 60
        let seconds = Int(elapsed) % 60
        Text("Recording \(appName) - \(String(format: "%d:%02d", minutes, seconds))")
      }
    } else {
      Text("Idle")
        .foregroundStyle(.secondary)
    }

    Divider()

    if monitor.isManualRecording {
      Button("Stop Recording") {
        monitor.stopManualRecording()
      }
    } else if !monitor.isRecording {
      Menu("Record Now") {
        ForEach(runningTargetApps, id: \.bundleIdentifier) { app in
          Button(app.localizedName ?? "Unknown") {
            if let bid = app.bundleIdentifier {
              monitor.startManualRecording(bundleID: bid)
            }
          }
        }
        if runningTargetApps.isEmpty {
          Text("No target apps running")
            .foregroundStyle(.secondary)
        }
      }
    }

    Divider()

    Button("Open Recordings Folder") {
      let url = monitor.saveDirectory
      try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      NSWorkspace.shared.open(url)
    }

    Button("Settings...") {
      openSettings()
      NSApplication.shared.activate(ignoringOtherApps: true)
    }
    .keyboardShortcut(",", modifiers: .command)

    Divider()

    Button("Quit Blackbox") {
      NSApplication.shared.terminate(nil)
    }
  }

  private var runningTargetApps: [NSRunningApplication] {
    NSWorkspace.shared.runningApplications.filter {
      guard let bid = $0.bundleIdentifier else { return false }
      return monitor.targetBundleIDs.contains(bid)
    }
  }
}
