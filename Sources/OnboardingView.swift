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
        case 1: microphoneStep
        case 2: notificationsStep
        case 3: systemAudioStep
        default: EmptyView()
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(32)

      Divider()

      HStack {
        if step > 0 && step < 3 {
          Button("Skip") { step += 1 }
        }
        Spacer()
        if step < 3 {
          Button("Continue") { advanceStep() }
            .keyboardShortcut(.defaultAction)
        } else {
          // System Audio step: permission granted on first recording
          Button("Complete Setup") { completeOnboarding() }
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

  private var systemAudioStep: some View {
    VStack(spacing: 16) {
      Image(systemName: "speaker.wave.2.fill")
        .font(.system(size: 48))
        .foregroundStyle(.blue)
      Text("System Audio Recording")
        .font(.title2.bold())
      Text(
        "Blackbox captures system audio to record both sides of your calls. It never records your screen - only audio."
      )
      .multilineTextAlignment(.center)
      .foregroundStyle(.secondary)
      .frame(maxWidth: 360)

      Text(
        "macOS will ask for permission when your first recording starts. Click Allow when prompted."
      )
      .font(.caption)
      .multilineTextAlignment(.center)
      .foregroundStyle(.tertiary)
      .frame(maxWidth: 360)
    }
  }

  // MARK: - Actions

  private func advanceStep() {
    switch step {
    case 1:
      Task {
        await AVCaptureDevice.requestAccess(for: .audio)
        step += 1
      }
    case 2:
      Task {
        let _ = try? await UNUserNotificationCenter.current().requestAuthorization(
          options: [.alert, .sound])
        step += 1
      }
    default:
      step += 1
    }
  }

  private func completeOnboarding() {
    // CATap permission prompt appears automatically on first recording attempt.
    // No manual pre-authorization needed, no app restart required.
    UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
    onComplete?()
  }
}
