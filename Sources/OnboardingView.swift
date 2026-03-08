import AVFoundation
import SwiftUI
import UserNotifications

struct OnboardingView: View {
  @State private var step = 0
  var onComplete: (() -> Void)?

  var body: some View {
    VStack(spacing: 0) {
      Group {
        switch step {
        case 0: welcomeStep
        case 1: screenRecordingStep
        case 2: microphoneStep
        case 3: notificationsStep
        case 4: doneStep
        default: EmptyView()
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(32)

      Divider()

      HStack {
        if step > 0 && step < 4 {
          Button("Skip") { step += 1 }
        }
        Spacer()
        if step < 4 {
          Button("Continue") { advanceStep() }
            .keyboardShortcut(.defaultAction)
        } else {
          Button("Get Started") { complete() }
            .keyboardShortcut(.defaultAction)
        }
      }
      .padding(16)
    }
    .frame(width: 480, height: 360)
  }

  // MARK: - Steps

  private var welcomeStep: some View {
    VStack(spacing: 16) {
      Image(nsImage: NSApplication.shared.applicationIconImage)
        .resizable()
        .frame(width: 80, height: 80)
      Text("Welcome to Blackbox")
        .font(.title.bold())
      Text(
        "Blackbox lives in your menu bar and automatically records audio from your calls in Chrome, Zoom, and Telegram."
      )
      .multilineTextAlignment(.center)
      .foregroundStyle(.secondary)
      .frame(maxWidth: 360)
    }
  }

  private var screenRecordingStep: some View {
    VStack(spacing: 16) {
      Image(systemName: "rectangle.dashed.badge.record")
        .font(.system(size: 48))
        .foregroundStyle(.blue)
      Text("Screen Recording")
        .font(.title2.bold())
      Text(
        "Blackbox uses Screen Recording to capture app audio via ScreenCaptureKit. It never records your screen - only audio."
      )
      .multilineTextAlignment(.center)
      .foregroundStyle(.secondary)
      .frame(maxWidth: 360)
      HStack(spacing: 8) {
        Image(
          systemName: CGPreflightScreenCaptureAccess()
            ? "checkmark.circle.fill" : "xmark.circle.fill"
        )
        .foregroundStyle(CGPreflightScreenCaptureAccess() ? .green : .red)
        Text(
          CGPreflightScreenCaptureAccess()
            ? "Permission granted" : "Permission required"
        )
        .foregroundStyle(.secondary)
      }
      .font(.caption)
    }
  }

  private var microphoneStep: some View {
    VStack(spacing: 16) {
      Image(systemName: "mic.fill")
        .font(.system(size: 48))
        .foregroundStyle(.blue)
      Text("Microphone Access")
        .font(.title2.bold())
      Text(
        "To capture your voice alongside app audio, Blackbox needs microphone access. Each is saved as a separate audio track."
      )
      .multilineTextAlignment(.center)
      .foregroundStyle(.secondary)
      .frame(maxWidth: 360)
    }
  }

  private var notificationsStep: some View {
    VStack(spacing: 16) {
      Image(systemName: "bell.badge.fill")
        .font(.system(size: 48))
        .foregroundStyle(.blue)
      Text("Notifications")
        .font(.title2.bold())
      Text(
        "Blackbox notifies you when recording starts and when a recording is saved, so you always know what's happening."
      )
      .multilineTextAlignment(.center)
      .foregroundStyle(.secondary)
      .frame(maxWidth: 360)
    }
  }

  private var doneStep: some View {
    VStack(spacing: 16) {
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 48))
        .foregroundStyle(.green)
      Text("You're All Set")
        .font(.title2.bold())
      Text(
        "Blackbox is running in your menu bar. Look for the waveform icon - it turns red when recording."
      )
      .multilineTextAlignment(.center)
      .foregroundStyle(.secondary)
      .frame(maxWidth: 360)
      Text("Tip: Enable \"Launch at Login\" in Settings so you never miss a recording.")
        .font(.caption)
        .foregroundStyle(.tertiary)
        .frame(maxWidth: 360)
    }
  }

  // MARK: - Actions

  private func advanceStep() {
    switch step {
    case 1:
      CGRequestScreenCaptureAccess()
      step += 1
    case 2:
      Task {
        await AVCaptureDevice.requestAccess(for: .audio)
        step += 1
      }
    case 3:
      Task {
        let _ = try? await UNUserNotificationCenter.current().requestAuthorization(
          options: [.alert, .sound])
        step += 1
      }
    default:
      step += 1
    }
  }

  private func complete() {
    UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
    onComplete?()
  }
}
