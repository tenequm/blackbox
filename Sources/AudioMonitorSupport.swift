import AVFoundation
import CoreAudio
import UserNotifications

protocol RecorderSession: AnyObject {
  var appName: String { get }
  func start() async throws
  func stop() async -> URL?
}

struct RecorderSessionConfiguration: Sendable {
  var bundleID: String?
  var appName: String
  var micEnabled: Bool
  var saveDirectory: URL
  var isManualRecording: Bool
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
  var excludedBundleIDs: Set<String> = []
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
          notifyOnStart: false,
          notifyOnSaved: false,
          notifyOnError: false
        )
      }

      let defaults = UserDefaults.standard
      let path = defaults.string(forKey: "saveDirectoryPath") ?? defaultSaveDirectoryPath
      let excludedBundleIDs =
        (defaults.string(forKey: "excludedBundleIDs") ?? "")
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
      return AudioMonitorSettings(
        autoRecord: defaults.object(forKey: "autoRecord") as? Bool ?? true,
        gracePeriod: defaults.double(forKey: "gracePeriod").clamped(to: 5...60, default: 5),
        micEnabled: defaults.object(forKey: "micEnabled") as? Bool ?? true,
        saveDirectory: URL(fileURLWithPath: path),
        notifyOnStart: defaults.object(forKey: "notifyOnStart") as? Bool ?? true,
        notifyOnSaved: defaults.object(forKey: "notifyOnSaved") as? Bool ?? true,
        notifyOnError: defaults.object(forKey: "notifyOnError") as? Bool ?? true,
        excludedBundleIDs: Set(excludedBundleIDs)
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
    }
  )
}
