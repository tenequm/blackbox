import AVFoundation
import AppKit
import Foundation
import ScreenCaptureKit
import UserNotifications

@Observable
final class AudioMonitor {
  private(set) var isRecording = false
  private(set) var currentAppName: String?
  private(set) var recordingStartTime: Date?
  private(set) var permissionNeeded = false
  private(set) var micPermissionNeeded = false
  private(set) var isManualRecording = false
  private(set) var errorMessage: String?
  private(set) var isPaused = false
  private(set) var graceCountdown: TimeInterval?
  private(set) var isSaving = false
  private var savingCount = 0

  private var sessions: [String: RecordingSession] = [:]
  private var monitoringTask: Task<Void, Never>?
  private var notificationTokens: [NSObjectProtocol] = []

  // Tracks when each app last had a meeting window visible
  private var meetingLastSeen: [String: Date] = [:]

  // Manual recording state
  private var manualRecorder: AudioRecorder?

  // Recording start HUD
  private let hud = RecordingHUD()

  var targetBundleIDs: Set<String> = []
  var meetingPatterns: [String] = []
  var gracePeriod: TimeInterval = 30
  var micEnabled: Bool = true
  var saveDirectory: URL = URL(fileURLWithPath: defaultSaveDirectoryPath)

  // Notification preferences
  var notifyOnStart: Bool = true
  var notifyOnSaved: Bool = true
  var notifyOnError: Bool = true

  func startMonitoring(skipPermissionRequests: Bool = false) {
    guard monitoringTask == nil else { return }
    loadSettings()

    // Check screen recording permission
    if !CGPreflightScreenCaptureAccess() {
      Log.info(Log.monitor, "monitor", "screen recording permission not granted")
      permissionNeeded = true
    }

    UNUserNotificationCenter.current().delegate = notificationDelegate

    // Request permissions if not yet determined (fallback for upgrade path
    // and users who close onboarding early). Skipped when onboarding will
    // handle permissions to avoid system prompts racing with the wizard.
    if !skipPermissionRequests {
      Task {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
          await AVCaptureDevice.requestAccess(for: .audio)
        }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        if settings.authorizationStatus == .notDetermined {
          let _ = try? await UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound])
        }
      }
    }

    // Register actionable notification category
    let revealAction = UNNotificationAction(identifier: "reveal", title: "Reveal in Finder")
    let playAction = UNNotificationAction(identifier: "play", title: "Play")
    let category = UNNotificationCategory(
      identifier: "recordingSaved", actions: [revealAction, playAction], intentIdentifiers: [])
    UNUserNotificationCenter.current().setNotificationCategories([category])

    let ws = NSWorkspace.shared.notificationCenter
    notificationTokens.append(
      ws.addObserver(
        forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
      ) {
        [weak self] _ in
        MainActor.assumeIsolated { self?.pollMeetingWindows() }
      }
    )
    notificationTokens.append(
      ws.addObserver(
        forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
      ) {
        [weak self] notification in
        let bundleID =
          (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
          .bundleIdentifier
        MainActor.assumeIsolated {
          guard let self, let bundleID else { return }
          self.meetingLastSeen.removeValue(forKey: bundleID)
          self.stopSession(bundleID: bundleID)
        }
      }
    )

    monitoringTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        self.loadSettings()
        self.pollMeetingWindows()
        try? await Task.sleep(for: .seconds(3))
      }
    }
  }

  /// Stops all monitoring and recording. Async to ensure files are finalized.
  func stopMonitoring() async {
    monitoringTask?.cancel()
    monitoringTask = nil
    for token in notificationTokens {
      NSWorkspace.shared.notificationCenter.removeObserver(token)
    }
    notificationTokens.removeAll()

    for (_, session) in sessions {
      await session.recorder.stop()
    }
    sessions.removeAll()

    if let recorder = manualRecorder {
      await recorder.stop()
      manualRecorder = nil
      isManualRecording = false
    }
    updateState()
  }

  // MARK: - Pause & Error

  func togglePause() {
    isPaused.toggle()
    if isPaused { graceCountdown = nil }
  }

  func clearError() { errorMessage = nil }

  private var errorGeneration = 0

  private func setError(_ message: String) {
    Log.error(Log.monitor, "monitor", message)
    errorMessage = message
    if notifyOnError { postErrorNotification(message: message) }
    errorGeneration += 1
    let gen = errorGeneration
    Task {
      try? await Task.sleep(for: .seconds(10))
      if errorGeneration == gen { errorMessage = nil }
    }
  }

  // MARK: - Manual Recording

  func startManualRecording() {
    startManualRecordingInternal()
  }

  private func startManualRecordingInternal(micOverride: Bool? = nil) {
    guard manualRecorder == nil else { return }

    let useMic = micOverride ?? micEnabled
    let recorder = AudioRecorder(
      appName: "Manual recording",
      micEnabled: useMic,
      saveDirectory: saveDirectory,
      onFailure: { [weak self] failure in
        Task { @MainActor [weak self] in
          self?.handleManualRecorderFailure(failure)
        }
      }
    )

    manualRecorder = recorder
    isManualRecording = true

    Task {
      do {
        try await recorder.start()
        recordingStartTime = Date()
        currentAppName = "Manual recording"
        isRecording = true
        hud.show(appName: "Manual recording", bundleID: nil)
      } catch {
        setError("Failed to start recording: \(error.localizedDescription)")
        manualRecorder = nil
        isManualRecording = false
        updateState()
      }
    }
  }

  private func handleManualRecorderFailure(_ failure: RecorderFailure) {
    guard let failedRecorder = manualRecorder else { return }
    let appName = currentAppName ?? failedRecorder.appName

    // Clear the failed recorder
    manualRecorder = nil
    isManualRecording = false

    // Save the failed recorder's file
    savingCount += 1
    isSaving = true
    Task {
      let url = await failedRecorder.stop()
      savingCount -= 1
      isSaving = savingCount > 0
      if let url, notifyOnSaved {
        postRecordingSavedNotification(appName: appName, fileURL: url)
      }
    }

    // Decide whether to auto-restart
    switch failure {
    case .permissionDenied:
      permissionNeeded = true
      updateState()
    case .micFailed:
      setError("Microphone lost - recording continues without mic")
      startManualRecordingInternal(micOverride: false)
    case .systemStopped, .deviceChangeFailed, .other:
      setError("Recording interrupted - restarting...")
      startManualRecordingInternal()
    }
  }

  func stopManualRecording() {
    guard let recorder = manualRecorder else { return }
    let appName = currentAppName ?? recorder.appName
    manualRecorder = nil
    isManualRecording = false
    savingCount += 1
    isSaving = true
    Task {
      let url = await recorder.stop()
      savingCount -= 1
      isSaving = savingCount > 0
      if let url, notifyOnSaved {
        postRecordingSavedNotification(appName: appName, fileURL: url)
      }
      updateState()
    }
  }

  // MARK: - Meeting Window Detection

  private func pollMeetingWindows() {
    if !CGPreflightScreenCaptureAccess() {
      permissionNeeded = true
      return
    }
    permissionNeeded = false

    // Check mic permission for menu bar warning (non-blocking)
    micPermissionNeeded =
      micEnabled && AVCaptureDevice.authorizationStatus(for: .audio) != .authorized

    guard !isPaused else { return }

    let runningApps = NSWorkspace.shared.runningApplications
    let windowList =
      CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]] ?? []

    // Stop sessions for apps removed from target list
    for bundleID in sessions.keys where !targetBundleIDs.contains(bundleID) {
      stopSession(bundleID: bundleID)
    }

    var minGraceRemaining: TimeInterval = .infinity

    for bundleID in targetBundleIDs {
      guard let app = runningApps.first(where: { $0.bundleIdentifier == bundleID }) else {
        if sessions[bundleID] != nil {
          stopSession(bundleID: bundleID)
          meetingLastSeen.removeValue(forKey: bundleID)
        }
        continue
      }

      let hasMeeting = windowList.contains { window in
        guard let pid = window[kCGWindowOwnerPID as String] as? Int32,
          pid == app.processIdentifier,
          let title = window[kCGWindowName as String] as? String,
          !title.isEmpty
        else { return false }
        return meetingPatterns.contains { title.localizedCaseInsensitiveContains($0) }
      }

      if hasMeeting {
        meetingLastSeen[bundleID] = Date()
        if sessions[bundleID] == nil {
          let appName = app.localizedName ?? bundleID.components(separatedBy: ".").last ?? bundleID
          startSession(bundleID: bundleID, appName: appName)
        }
      } else if sessions[bundleID] != nil {
        let lastSeen = meetingLastSeen[bundleID] ?? Date.distantPast
        let elapsed = Date().timeIntervalSince(lastSeen)
        if elapsed >= gracePeriod {
          stopSession(bundleID: bundleID)
          meetingLastSeen.removeValue(forKey: bundleID)
        } else {
          minGraceRemaining = min(minGraceRemaining, gracePeriod - elapsed)
        }
      }
    }

    graceCountdown = minGraceRemaining.isFinite ? minGraceRemaining : nil
  }

  // MARK: - Session Management

  private func startSession(bundleID: String, appName: String, micOverride: Bool? = nil) {
    let useMic = micOverride ?? micEnabled
    let recorder = AudioRecorder(
      bundleID: bundleID,
      appName: appName,
      micEnabled: useMic,
      saveDirectory: saveDirectory,
      onFailure: { [weak self] failure in
        Task { @MainActor [weak self] in
          self?.handleSessionFailure(failure, bundleID: bundleID, appName: appName)
        }
      }
    )

    Log.info(Log.monitor, "monitor", "starting session for \(appName) (\(bundleID))")
    sessions[bundleID] = RecordingSession(
      bundleID: bundleID,
      appName: appName,
      recorder: recorder,
      startTime: Date()
    )

    Task {
      do {
        try await recorder.start()
        hud.show(appName: appName, bundleID: bundleID)
        if notifyOnStart { postRecordingStartedNotification(appName: appName) }
        updateState()
      } catch {
        setError("Failed to record \(appName): \(error.localizedDescription)")
        if let scError = error as? SCStreamError, scError.code == .userDeclined {
          permissionNeeded = true
        }
        // Only remove if this session's recorder is still the current one
        // (stopSession may have already removed and replaced it)
        if sessions[bundleID]?.recorder === recorder {
          sessions.removeValue(forKey: bundleID)
        }
        updateState()
      }
    }
  }

  private func handleSessionFailure(
    _ failure: RecorderFailure, bundleID: String, appName: String
  ) {
    // Save the current recording first
    stopSession(bundleID: bundleID)

    switch failure {
    case .permissionDenied:
      permissionNeeded = true
    case .micFailed:
      setError("Microphone lost - recording continues without mic")
      startSession(bundleID: bundleID, appName: appName, micOverride: false)
    case .systemStopped:
      Log.info(Log.monitor, "monitor", "auto-restarting session for \(appName)")
      startSession(bundleID: bundleID, appName: appName)
    case .deviceChangeFailed:
      Log.info(Log.monitor, "monitor", "restarting session for \(appName) after device change")
      startSession(bundleID: bundleID, appName: appName)
    case .other(let msg):
      setError("Recording of \(appName): \(msg)")
      // Re-poll to restart if meeting window is still there
      pollMeetingWindows()
    }
  }

  private func stopSession(bundleID: String) {
    guard let session = sessions.removeValue(forKey: bundleID) else { return }
    Log.info(Log.monitor, "monitor", "stopping session for \(session.appName) (\(bundleID))")
    savingCount += 1
    isSaving = true
    Task {
      let url = await session.recorder.stop()
      savingCount -= 1
      isSaving = savingCount > 0
      if let url, notifyOnSaved {
        postRecordingSavedNotification(appName: session.appName, fileURL: url)
      }
      updateState()
    }
  }

  private func updateState() {
    guard !isManualRecording else { return }
    let active = sessions.values.sorted { $0.startTime < $1.startTime }
    isRecording = !active.isEmpty
    if let first = active.first {
      if active.count == 1 {
        currentAppName = first.appName
      } else if active.count == 2 {
        currentAppName = "\(active[0].appName), \(active[1].appName)"
      } else {
        currentAppName = "\(active.count) apps"
      }
      recordingStartTime = first.startTime
    } else {
      currentAppName = nil
      recordingStartTime = nil
    }
  }

  private func loadSettings() {
    let defaults = UserDefaults.standard

    let raw = defaults.string(forKey: "targetBundleIDs") ?? defaultTargetBundleIDsJSON
    if let data = raw.data(using: .utf8),
      let ids = try? JSONDecoder().decode([String].self, from: data)
    {
      targetBundleIDs = Set(ids)
    }

    let patternsRaw = defaults.string(forKey: "meetingPatterns") ?? defaultMeetingPatternsJSON
    if let data = patternsRaw.data(using: .utf8),
      let patterns = try? JSONDecoder().decode([String].self, from: data)
    {
      meetingPatterns = patterns
    }

    gracePeriod = defaults.double(forKey: "gracePeriod").clamped(to: 5...60, default: 30)
    micEnabled = defaults.object(forKey: "micEnabled") as? Bool ?? true
    let path = defaults.string(forKey: "saveDirectoryPath") ?? defaultSaveDirectoryPath
    saveDirectory = URL(fileURLWithPath: path)
    notifyOnStart = defaults.object(forKey: "notifyOnStart") as? Bool ?? true
    notifyOnSaved = defaults.object(forKey: "notifyOnSaved") as? Bool ?? true
    notifyOnError = defaults.object(forKey: "notifyOnError") as? Bool ?? true
  }
}

// MARK: - Notifications

private let notificationDelegate = NotificationDelegate()

private func postRecordingSavedNotification(appName: String, fileURL: URL) {
  let content = UNMutableNotificationContent()
  content.title = "Recording Saved"
  content.body = "\(appName) - \(fileURL.lastPathComponent)"
  content.sound = .default
  content.userInfo = ["filePath": fileURL.path]
  content.categoryIdentifier = "recordingSaved"

  let request = UNNotificationRequest(
    identifier: UUID().uuidString, content: content, trigger: nil)
  UNUserNotificationCenter.current().add(request)
}

private func postRecordingStartedNotification(appName: String) {
  let content = UNMutableNotificationContent()
  content.title = "Recording Started"
  content.body = appName
  let request = UNNotificationRequest(
    identifier: UUID().uuidString, content: content, trigger: nil)
  UNUserNotificationCenter.current().add(request)
}

private func postErrorNotification(message: String) {
  let content = UNMutableNotificationContent()
  content.title = "Blackbox Error"
  content.body = message
  content.sound = .default
  let request = UNNotificationRequest(
    identifier: UUID().uuidString, content: content, trigger: nil)
  UNUserNotificationCenter.current().add(request)
}

private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate,
  @unchecked Sendable
{
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse
  ) async {
    guard let path = response.notification.request.content.userInfo["filePath"] as? String
    else { return }
    let url = URL(fileURLWithPath: path)
    await MainActor.run {
      switch response.actionIdentifier {
      case "play":
        NSWorkspace.shared.open(url)
      default:
        NSWorkspace.shared.activateFileViewerSelecting([url])
      }
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .sound]
  }
}

private struct RecordingSession {
  let bundleID: String
  let appName: String
  let recorder: AudioRecorder
  let startTime: Date
}

extension Double {
  fileprivate func clamped(to range: ClosedRange<Double>, default defaultValue: Double) -> Double {
    self == 0 ? defaultValue : min(max(self, range.lowerBound), range.upperBound)
  }
}
