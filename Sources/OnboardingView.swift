import AVFoundation
import CoreGraphics
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
          Button("Complete Setup") { advanceStep() }
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
        "Blackbox captures system audio to record both sides of your calls. On macOS, this uses the Screen Recording permission - but Blackbox never records your screen, only audio."
      )
      .multilineTextAlignment(.center)
      .foregroundStyle(.secondary)
      .frame(maxWidth: 360)

      Button("Open System Settings") {
        if let url = URL(
          string:
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
        ) {
          NSWorkspace.shared.open(url)
        }
      }
      .font(.caption)
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
    case 3:
      if !CGPreflightScreenCaptureAccess() {
        CGRequestScreenCaptureAccess()
      }
      // BlackboxApp's launch gate owns `hasCompletedOnboarding`: it treats
      // CGPreflightScreenCaptureAccess as source of truth on next launch. If
      // the user denies the TCC prompt, onboarding re-appears.
      onComplete?()
    default:
      step += 1
    }
  }
}
