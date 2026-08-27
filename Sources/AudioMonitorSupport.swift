import AVFoundation
import CoreAudio
import CoreGraphics
import UserNotifications

protocol RecorderSession: AnyObject {
  var appName: String { get }
  func start() async throws
  /// The recording *directory* that reached disk, or nil if nothing did.
  /// Ask `RecordingStore.audioURL(in:)` for the audio inside it.
  func stop() async -> URL?
}

struct RecorderSessionConfiguration: Sendable {
  var bundleID: String?
  var appName: String
  var micEnabled: Bool
  var saveDirectory: URL
  var isManualRecording: Bool
  var titlePrefix: String = ""
}

protocol RecorderSessionFactory {
  func makeRecorder(
    configuration: RecorderSessionConfiguration,
    onFailure: (@Sendable (RecorderFailure) -> Void)?,
    onAudioLevel: (@Sendable (Float) -> Void)?,
    onLowDiskSpace: (@Sendable (Int64) -> Void)?,
    onContinuity: (@Sendable () -> Void)?
  ) -> any RecorderSession
}

struct LiveRecorderSessionFactory: RecorderSessionFactory {
  func makeRecorder(
    configuration: RecorderSessionConfiguration,
    onFailure: (@Sendable (RecorderFailure) -> Void)?,
    onAudioLevel: (@Sendable (Float) -> Void)?,
    onLowDiskSpace: (@Sendable (Int64) -> Void)?,
    onContinuity: (@Sendable () -> Void)?
  ) -> any RecorderSession {
    AudioRecorder(
      bundleID: configuration.bundleID,
      appName: configuration.appName,
      micEnabled: configuration.micEnabled,
      saveDirectory: configuration.saveDirectory,
      isManualRecording: configuration.isManualRecording,
      titlePrefix: configuration.titlePrefix,
      onFailure: onFailure,
      onAudioLevel: onAudioLevel,
      onLowDiskSpace: onLowDiskSpace,
      onContinuity: onContinuity
    )
  }
}

extension AudioRecorder: RecorderSession {}

@MainActor
protocol AudioMonitorHUD: AnyObject {
  func showRecordingStarted(appName: String)
  func showRecordingSaved(appName: String)
  func showError(message: String)
  var lastToast: HUDToast? { get }
}

extension RecordingHUD: AudioMonitorHUD {}

struct AudioMonitorSettings: Sendable {
  var autoRecord: Bool
  var gracePeriod: TimeInterval
  var micEnabled: Bool
  var saveDirectory: URL
  var notifyOnStart: Bool
  var notifyOnSaved: Bool
  var notifyOnError: Bool
  var namePrefixTemplate: String = ""
  var excludedBundleIDs: Set<String> = []

  /// Parses the comma-separated `excludedBundleIDs` UserDefaults value.
  /// Single source of truth for the storage format (also written by SettingsView).
  static func parseBundleIDList(_ raw: String) -> [String] {
    raw.split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }
}

/// Resolves a recording-name prefix template into a concrete string.
/// Plain substitution of YYYY/YY/MM/DD tokens - deliberately not DateFormatter,
/// where uppercase YY/DD mean week-based year and day-of-year.
func formatNamePrefix(template: String, date: Date) -> String {
  guard !template.isEmpty else { return "" }
  let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
  let year = parts.year ?? 0
  return
    template
    .replacingOccurrences(of: "YYYY", with: String(format: "%04d", year))
    .replacingOccurrences(of: "YY", with: String(format: "%02d", year % 100))
    .replacingOccurrences(of: "MM", with: String(format: "%02d", parts.month ?? 0))
    .replacingOccurrences(of: "DD", with: String(format: "%02d", parts.day ?? 0))
}

struct AudioMonitorDependencies {
  var recorderFactory: any RecorderSessionFactory
  var hud: any AudioMonitorHUD
  var loadSettings: @MainActor () -> AudioMonitorSettings
  var microphoneAuthorizationStatus: @MainActor () -> AVAuthorizationStatus
  var requestMicrophoneAccessIfNeeded: @MainActor () async -> Void
  var notifyPermissionLost: @MainActor () async -> Void
  var findActiveCallingProcesses: @MainActor () -> [String?]
  var now: @MainActor () -> Date
  var sleep: @Sendable (Duration) async -> Void
  /// Called with the recording *directory* for every recording that reaches
  /// disk, including ones ended by a recorder failure or by quit. Wired to the
  /// transcription coordinator in `BlackboxApp`; a no-op by default so the
  /// monitor stays independent of it.
  ///
  /// A directory, not the audio file: that is what `RecorderSession.stop()`
  /// returns, and a consumer that assumed otherwise and climbed a level with
  /// `deletingLastPathComponent()` once enqueued the whole recordings folder
  /// as a job.
  var onRecordingSaved: @MainActor (URL) -> Void = { _ in }
  /// Whether Screen Recording - which is what system audio capture rides on -
  /// is currently granted. Polled rather than inferred from a failed recording:
  /// the menu bar used to look healthy until the first recording failed, which
  /// meant a denied user could sit through a whole call capturing nothing.
  /// `CGPreflightScreenCaptureAccess` is cheap and never prompts, which is
  /// exactly what makes it safe to call on the settings poll.
  /// Defaults to granted so tests that build this struct by hand are unaffected.
  var screenCaptureAccessGranted: @MainActor () -> Bool = { true }

  static let live = AudioMonitorDependencies(
    recorderFactory: LiveRecorderSessionFactory(),
    hud: RecordingHUD(),
    loadSettings: {
      if BlackboxTestMode.isEnabled {
        return AudioMonitorSettings(
          autoRecord: false,
          gracePeriod: 5,
          micEnabled: true,
          saveDirectory: BlackboxTestMode.saveDirectoryOverride
            ?? URL(fileURLWithPath: defaultSaveDirectoryPath),
          // Toasts stay on under --ui-test-mode so the smoke suite can assert
          // the HUD actually fired; without this the panel never shows at all.
          notifyOnStart: true,
          notifyOnSaved: true,
          notifyOnError: true,
          namePrefixTemplate: ""
        )
      }

      let defaults = UserDefaults.standard
      let path = defaults.string(forKey: SettingsKeys.saveDirectoryPath) ?? defaultSaveDirectoryPath
      return AudioMonitorSettings(
        autoRecord: defaults.object(forKey: SettingsKeys.autoRecord) as? Bool ?? true,
        gracePeriod: defaults.double(forKey: SettingsKeys.gracePeriod).clamped(
          to: 5...60, default: 5),
        micEnabled: defaults.object(forKey: SettingsKeys.micEnabled) as? Bool ?? true,
        saveDirectory: URL(fileURLWithPath: path),
        notifyOnStart: defaults.object(forKey: SettingsKeys.notifyOnStart) as? Bool ?? true,
        notifyOnSaved: defaults.object(forKey: SettingsKeys.notifyOnSaved) as? Bool ?? true,
        notifyOnError: defaults.object(forKey: SettingsKeys.notifyOnError) as? Bool ?? true,
        namePrefixTemplate: defaults.string(forKey: SettingsKeys.namePrefixTemplate) ?? "YYMM-DD-",
        excludedBundleIDs: Set(
          AudioMonitorSettings.parseBundleIDList(
            defaults.string(forKey: SettingsKeys.excludedBundleIDs) ?? ""))
      )
    },
    microphoneAuthorizationStatus: {
      AVCaptureDevice.authorizationStatus(for: .audio)
    },
    requestMicrophoneAccessIfNeeded: {
      if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
        await AVCaptureDevice.requestAccess(for: .audio)
      }
    },
    notifyPermissionLost: {
      let content = UNMutableNotificationContent()
      content.title = "Recording stopped"
      content.body =
        "System Audio Recording permission was revoked. Re-authorize in System Settings > Privacy & Security to resume."
      content.sound = .default
      let request = UNNotificationRequest(
        identifier: "audioRecordingPermissionLost",
        content: content,
        trigger: nil
      )
      try? await UNUserNotificationCenter.current().add(request)
    },
    findActiveCallingProcesses: {
      let myPID = ProcessInfo.processInfo.processIdentifier
      guard let processes = try? AudioHardwareSystem.shared.processes else { return [] }
      return
        processes
        .filter { (try? $0.isRunningInput) == true && (try? $0.isRunningOutput) == true }
        .filter {
          guard let pid = try? $0.pid else { return false }
          return pid != myPID
        }
        .map { try? $0.bundleID }
    },
    now: { Date() },
    sleep: { duration in
      try? await Task.sleep(for: duration)
    },
    screenCaptureAccessGranted: { CGPreflightScreenCaptureAccess() }
  )
}
