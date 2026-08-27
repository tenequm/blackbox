import AVFoundation
import CoreGraphics
import SwiftUI
import UserNotifications

struct OnboardingView: View {
  @State private var step = 0
  @State private var micDenied = false
  @State private var screenCaptureDenied = false
  @State private var screenCaptureGranted = false
  @State private var pollTask: Task<Void, Never>?
  @AccessibilityFocusState private var stepFocused: Bool
  var onComplete: (() -> Void)?

  static let windowSize = CGSize(width: 480, height: 380)
  private static let stepCount = 4
  /// Index of the final step. Every bound below was a bare `3`, so adding a
  /// step meant changing the count and five literals - and the count is the one
  /// that would not be forgotten.
  private static let lastStep = stepCount - 1

  var body: some View {
    VStack(spacing: 0) {
      Group {
        switch step {
        case 0: welcomeStep
        case 1: microphoneStep
        case 2: notificationsStep
        case Self.lastStep: systemAudioStep
        default: EmptyView()
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(32)
      // VoiceOver focus is moved onto each new step. Without it the user
      // presses Continue, stays focused on the button, and the entire screen
      // changes underneath them in silence - in the flow whose whole job is
      // granting the permissions the app cannot work without.
      .accessibilityFocused($stepFocused)

      Divider()

      HStack {
        Text("Step \(step + 1) of \(Self.stepCount)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityAddTraits(.isHeader)
        Spacer()
        if step > 0 && step < Self.lastStep {
          Button("Back") { step -= 1 }
        }
        if step > 0 && step < Self.lastStep {
          Button("Skip") { step += 1 }
        }
        Button(primaryButtonTitle) { advanceStep() }
          .keyboardShortcut(.defaultAction)
      }
      .padding(16)
    }
    .frame(width: Self.windowSize.width, height: Self.windowSize.height)
    .onChange(of: step) { _, _ in
      stepFocused = true
    }
    .onDisappear { pollTask?.cancel() }
  }

  private var primaryButtonTitle: String {
    if step < Self.lastStep { return "Continue" }
    if screenCaptureGranted { return "Quit and Reopen" }
    if screenCaptureDenied { return "Open System Settings…" }
    return "Grant Access"
  }

  // MARK: - Steps

  private var welcomeStep: some View {
    VStack(spacing: 16) {
      Image(nsImage: NSApplication.shared.applicationIconImage)
        .resizable()
        .frame(width: 80, height: 80)
      Text("Welcome to Blackbox")
        .font(.title.bold())
        .accessibilityAddTraits(.isHeader)
      Text(
        "Blackbox lives in your menu bar and automatically records audio from your calls in Chrome, Zoom, and Telegram."
      )
      .multilineTextAlignment(.center)
      .foregroundStyle(.secondary)
      .frame(maxWidth: 360)
    }
  }

  private var microphoneStep: some View {
    VStack(spacing: 16) {
      Image(systemName: "mic.fill")
        .font(.system(size: 48))
        .foregroundStyle(micDenied ? .orange : .blue)
      Text("Microphone Access")
        .font(.title2.bold())
        .accessibilityAddTraits(.isHeader)
      if micDenied {
        // The result used to be discarded, so a mis-click on Deny walked the
        // user straight past this with a reassuring "Continue" - and every
        // recording afterwards was missing their own voice, which they would
        // not discover until playback.
        Text(
          "Microphone access was denied. Blackbox will still record the other side of your calls, but not your own voice."
        )
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
        .frame(maxWidth: 360)
        Button("Open System Settings…") {
          openSettings(pane: .microphone)
        }
        .font(.caption)
      } else {
        Text(
          "To capture your voice alongside app audio, Blackbox needs microphone access. Each is saved as a separate audio track."
        )
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
        .frame(maxWidth: 360)
      }
    }
  }

  private var notificationsStep: some View {
    VStack(spacing: 16) {
      Image(systemName: "bell.badge.fill")
        .font(.system(size: 48))
        .foregroundStyle(.blue)
      Text("Notifications")
        .font(.title2.bold())
        .accessibilityAddTraits(.isHeader)
      // Says what the permission is actually used for. It used to promise
      // alerts on start and save; those are in-app toasts that need no
      // permission, and the one real notification - the one that matters - went
      // unmentioned. A user who granted on the old premise, saw nothing in
      // Notification Center, and turned Blackbox's notifications off would have
      // silently lost the alert that tells them a call is no longer recording.
      Text(
        "If macOS revokes recording permission mid-call, Blackbox alerts you - so a call is never silently lost."
      )
      .multilineTextAlignment(.center)
      .foregroundStyle(.secondary)
      .frame(maxWidth: 360)
    }
  }

  private var systemAudioStep: some View {
    VStack(spacing: 16) {
      Image(
        systemName: screenCaptureDenied ? "exclamationmark.triangle.fill" : "speaker.wave.2.fill"
      )
      .font(.system(size: 48))
      .foregroundStyle(screenCaptureDenied ? .orange : .blue)
      Text("System Audio Recording")
        .font(.title2.bold())
        .accessibilityAddTraits(.isHeader)

      if screenCaptureGranted {
        Text(
          "Granted. macOS only applies this permission to a fresh launch, so Blackbox needs to reopen to finish setup."
        )
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
        .frame(maxWidth: 360)
      } else if screenCaptureDenied {
        // Arriving here already-denied shows no prompt at all, so the old code
        // closed the window on a permission the user never saw asked for.
        Text(
          "Screen Recording is currently denied, so Blackbox cannot capture system audio. Enable it in System Settings and this screen will update on its own."
        )
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
        .frame(maxWidth: 360)
      } else {
        Text(
          "Blackbox captures system audio to record both sides of your calls. On macOS, this uses the Screen Recording permission - but Blackbox never records your screen, only audio."
        )
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
        .frame(maxWidth: 360)
      }

      Button("Continue Without System Audio") { onComplete?() }
        .font(.caption)
        .buttonStyle(.link)
    }
  }

  // MARK: - Actions

  private func advanceStep() {
    switch step {
    case 1:
      Task {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        // Already-denied returns false without prompting, which is exactly the
        // case that needs the System Settings route rather than another click.
        if granted || AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
          step += 1
        } else {
          micDenied = true
        }
      }
    case 2:
      Task {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(
          options: [.alert, .sound])
        // Deliberately advances either way: a denied notification permission
        // costs one alert, not the product.
        step += 1
      }
    case Self.lastStep:
      if screenCaptureGranted {
        relaunch()
      } else if screenCaptureDenied {
        openSettings(pane: .screenCapture)
      } else if CGPreflightScreenCaptureAccess() {
        onComplete?()
      } else if CGRequestScreenCaptureAccess() {
        screenCaptureGranted = true
      } else {
        screenCaptureDenied = true
        startPollingForScreenCaptureAccess()
      }
    default:
      step += 1
    }
  }

  /// macOS never calls back when a TCC switch is flipped, so the only way to
  /// notice is to ask. Preflight is cheap and does not prompt.
  private func startPollingForScreenCaptureAccess() {
    guard pollTask == nil else { return }
    pollTask = Task {
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        if CGPreflightScreenCaptureAccess() {
          screenCaptureDenied = false
          screenCaptureGranted = true
          return
        }
      }
    }
  }

  /// Screen Recording only takes effect for a process launched after the grant,
  /// so finishing setup means starting over. Nothing told the user that, and
  /// the app would sit there apparently broken.
  private func relaunch() {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(
      at: Bundle.main.bundleURL, configuration: configuration
    ) { _, _ in
      // Scheduled on the run loop, not with `Task { @MainActor }`. Terminating
      // from inside a main-queue block starves the main queue for the whole
      // nested run loop `.terminateLater` spins up, and both of the paths that
      // reply - including the 8s timeout - are main-actor tasks. Neither ever
      // runs, no reply is ever made, and the app hangs until Force Quit.
      RunLoop.main.perform {
        MainActor.assumeIsolated { NSApplication.shared.terminate(nil) }
      }
    }
  }

  private func openSettings(pane: PrivacyPane) {
    openPrivacySettings(pane: pane)
  }
}
