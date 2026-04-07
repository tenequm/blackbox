import AVFoundation
import AppKit
import CoreAudio
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
  private(set) var graceCountdown: TimeInterval?
  private(set) var isSaving = false
  private(set) var formattedElapsed: String?
  private(set) var audioLevel: Float = 0
  private var savingCount = 0

  // Auto-recording triggered by call detection
  private var autoRecorder: AudioRecorder?
  private var autoRecordingAppName: String?
  private var autoRecordingBundleID: String?
  // Manual recording triggered by user
  private var manualRecorder: AudioRecorder?

  private var settingsTask: Task<Void, Never>?
  private var elapsedTimer: Timer?
  private var graceTask: Task<Void, Never>?

  // Restart rate limiting: max 3 restarts within 30 seconds
  private var autoRestartCount = 0
  private var autoRestartWindowStart: Date?
  private var manualRestartCount = 0
  private var manualRestartWindowStart: Date?

  private var micPollingTask: Task<Void, Never>?
  private var lastKnownMicRunning = false

  private let hud = RecordingHUD()

  // Settings
  var autoRecord: Bool = true
  var gracePeriod: TimeInterval = 5
  var micEnabled: Bool = true
  var saveDirectory: URL = URL(fileURLWithPath: defaultSaveDirectoryPath)
  var notifyOnStart: Bool = true
  var notifyOnSaved: Bool = true
  var notifyOnError: Bool = true

  private var errorGeneration = 0

  // MARK: - Monitoring Lifecycle

  func startMonitoring(skipPermissionRequests: Bool = false) {
    guard settingsTask == nil else {
      Log.info(Log.monitor, "monitor", "startMonitoring skipped: already running")
      return
    }
    Log.info(Log.monitor, "monitor", "startMonitoring called (skip=\(skipPermissionRequests))")
    loadSettings()
    Log.info(
      Log.monitor, "monitor",
      "settings loaded: autoRecord=\(autoRecord), gracePeriod=\(gracePeriod), micEnabled=\(micEnabled)"
    )

    // CATap has no preflight API - permission is checked on first AudioHardwareCreateProcessTap call.
    // permissionNeeded will be set to true if recording fails with .permissionDenied.

    if !skipPermissionRequests {
      Task {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
          await AVCaptureDevice.requestAccess(for: .audio)
        }
      }
    }

    // Start call detection polling
    setupCallDetection()

    // Periodically reload settings
    settingsTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(5))
        guard let self else { return }
        self.loadSettings()
      }
    }
  }

  func stopMonitoring() async {
    settingsTask?.cancel()
    settingsTask = nil
    micPollingTask?.cancel()
    micPollingTask = nil
    stopElapsedTimer()
    cancelGracePeriod()

    if let recorder = autoRecorder {
      await recorder.stop()
      autoRecorder = nil
    }

    if let recorder = manualRecorder {
      await recorder.stop()
      manualRecorder = nil
      isManualRecording = false
    }

    isRecording = false
    currentAppName = nil
    recordingStartTime = nil
  }

  // MARK: - Error

  func clearError() { errorMessage = nil }

  func setError(_ message: String) {
    Log.error(Log.monitor, "monitor", message)
    errorMessage = message
    notifyError(message: message)
    errorGeneration += 1
    let gen = errorGeneration
    Task {
      try? await Task.sleep(for: .seconds(10))
      if errorGeneration == gen { errorMessage = nil }
    }
  }

  private func handleLowDiskSpace(_ remainingBytes: Int64) {
    let mb = remainingBytes / 1_000_000
    setError("Low disk space (\(mb) MB remaining)")
  }

  // MARK: - Elapsed Timer

  private func startElapsedTimer() {
    guard elapsedTimer == nil else { return }
    tickElapsed()
    elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.tickElapsed()
      }
    }
  }

  private func stopElapsedTimer() {
    elapsedTimer?.invalidate()
    elapsedTimer = nil
    formattedElapsed = nil
  }

  private func tickElapsed() {
    guard let start = recordingStartTime else {
      formattedElapsed = nil
      return
    }
    let total = max(0, Int(Date().timeIntervalSince(start)))
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    formattedElapsed =
      h > 0
      ? String(format: "%d:%02d:%02d", h, m, s)
      : String(format: "%d:%02d", m, s)
  }

  // MARK: - Manual Recording

  func startManualRecording() {
    guard manualRecorder == nil else {
      Log.info(Log.monitor, "monitor", "startManualRecording skipped: already recording")
      return
    }

    let useMic = micEnabled
    let recorder = AudioRecorder(
      appName: "Manual recording",
      micEnabled: useMic,
      saveDirectory: saveDirectory,
      onFailure: { [weak self] failure in
        Task { @MainActor [weak self] in
          self?.handleManualRecorderFailure(failure)
        }
      },
      onAudioLevel: { [weak self] level in
        Task { @MainActor [weak self] in
          self?.audioLevel = level
        }
      },
      onLowDiskSpace: { [weak self] remaining in
        Task { @MainActor [weak self] in
          self?.handleLowDiskSpace(remaining)
        }
      }
    )

    manualRecorder = recorder
    isManualRecording = true

    Task {
      do {
        try await recorder.start()
        UserDefaults.standard.set(true, forKey: "audioRecordingGranted")
        permissionNeeded = false
        manualRestartCount = 0
        manualRestartWindowStart = nil
        recordingStartTime = Date()
        currentAppName = "Manual recording"
        isRecording = true
        startElapsedTimer()
        notifyRecordingStarted(appName: "Manual recording")
      } catch {
        setError("Failed to start recording: \(error.localizedDescription)")
        manualRecorder = nil
        isManualRecording = false
        updateAutoState()
      }
    }
  }

  private func handleManualRecorderFailure(_ failure: RecorderFailure) {
    guard let failedRecorder = manualRecorder else {
      Log.info(Log.monitor, "monitor", "handleManualRecorderFailure skipped: recorder already nil")
      return
    }
    manualRecorder = nil
    isManualRecording = false
    stopElapsedTimer()

    savingCount += 1
    isSaving = true
    Task {
      _ = await failedRecorder.stop()
      savingCount -= 1
      isSaving = savingCount > 0
    }

    switch failure {
    case .permissionDenied:
      permissionNeeded = true
      notifyPermissionLost()
      updateAutoState()
    case .lowDiskSpace:
      setError("Recording stopped - not enough disk space")
      updateAutoState()
    case .systemStopped, .other:
      if shouldAllowRestart(
        count: &manualRestartCount, windowStart: &manualRestartWindowStart)
      {
        setError("Recording interrupted - restarting...")
        startManualRecording()
      } else {
        setError("Recording failed repeatedly")
      }
    }
  }

  func forceStopAutoRecording() {
    cancelGracePeriod()
    stopAutoRecording()
  }

  func stopManualRecording() {
    guard let recorder = manualRecorder else { return }
    let appName = currentAppName ?? recorder.appName
    manualRecorder = nil
    isManualRecording = false
    stopElapsedTimer()
    savingCount += 1
    isSaving = true
    Task {
      let url = await recorder.stop()
      savingCount -= 1
      isSaving = savingCount > 0
      if url != nil {
        notifyRecordingSaved(appName: appName)
      }
      updateAutoState()
      // Force re-evaluation so auto-recording starts if a call is still active
      lastKnownMicRunning = false
      evaluateCallState()
    }
  }

  // MARK: - Call Detection (macOS 14.2+)

  private func setupCallDetection() {
    let callers = Self.findActiveCallingProcesses()
    lastKnownMicRunning = !callers.isEmpty
    Log.info(
      Log.monitor, "monitor",
      "call detection started: polling every 3s, activeCallers=\(callers.count)"
    )

    // Check current state in case app starts mid-call
    if let first = callers.first {
      handleMicBecameActive(appBundleID: first)
    }

    // Poll every 3 seconds for active calling processes
    micPollingTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(3))
        guard let self else { return }
        self.evaluateCallState()
      }
    }
  }

  // MARK: - Process Query Functions

  /// Returns external processes with both active mic input AND audio output (i.e. calls).
  /// Filters out our own PID.
  nonisolated private static func findActiveCallingProcesses() -> [String?] {
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
  }

  // MARK: - Call State Evaluation

  /// Re-evaluate call state by checking which external processes have active calls.
  /// Called from polling loop every 3 seconds.
  private func evaluateCallState() {
    let callers = Self.findActiveCallingProcesses()
    let running = !callers.isEmpty

    if running != lastKnownMicRunning {
      Log.info(
        Log.monitor, "monitor",
        "call state changed: activeCallers=\(callers.count), running=\(running)")
      lastKnownMicRunning = running
      if running {
        // Single caller: per-app capture. Multiple callers: nil → display-wide only.
        let bundleID = callers.count == 1 ? callers.first ?? nil : nil
        handleMicBecameActive(appBundleID: bundleID)
      } else {
        handleMicBecameInactive()
      }
    } else if running, autoRecord, autoRecorder == nil, !isRecording, !isManualRecording {
      // Recovery: callers active but no recording running (e.g., start() failed previously).
      Log.info(Log.monitor, "monitor", "retrying auto-recording for active call")
      handleMicBecameActive(appBundleID: callers.first ?? nil)
    }
  }

  /// Resolve helper subprocess bundle IDs to the parent app.
  /// e.g. "com.google.Chrome.helper.renderer" → "com.google.Chrome"
  private static func resolveParentBundleID(_ bundleID: String) -> String {
    let parts = bundleID.split(separator: ".")
    if let idx = parts.firstIndex(where: { $0 == "helper" }), idx > 1 {
      return parts[..<idx].joined(separator: ".")
    }
    return bundleID
  }

  /// Resolve a bundle ID to a human-readable app name.
  private static func resolveAppName(bundleID: String?) -> String {
    guard let bundleID else { return "Call" }
    let resolved = resolveParentBundleID(bundleID)
    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: resolved).first,
      let name = app.localizedName
    {
      return name
    }
    // Fallback: try original bundle ID if parent resolution found nothing
    if resolved != bundleID,
      let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
      let name = app.localizedName
    {
      return name
    }
    // Last resort: extract last component of bundle ID (e.g. "com.zoom.us" -> "zoom")
    let components = bundleID.split(separator: ".")
    if let last = components.last, last != "app" {
      return String(last)
    }
    return "Call"
  }

  // MARK: - Auto Recording

  private func handleMicBecameActive(appBundleID: String? = nil) {
    cancelGracePeriod()

    guard autoRecord, !isRecording, !isManualRecording else {
      Log.info(
        Log.monitor, "monitor",
        "handleMicBecameActive skipped: autoRecord=\(autoRecord), isRecording=\(isRecording), isManualRecording=\(isManualRecording)"
      )
      return
    }

    // CATap permission is checked when AudioRecorder.start() creates the process tap.
    // If denied, the failure callback sets permissionNeeded = true.

    autoRecordingBundleID = appBundleID.map { Self.resolveParentBundleID($0) }
    autoRecordingAppName = Self.resolveAppName(bundleID: appBundleID)
    loadSettings()
    startAutoRecording()
  }

  private func handleMicBecameInactive() {
    guard autoRecorder != nil else {
      Log.info(Log.monitor, "monitor", "handleMicBecameInactive skipped: no active auto-recording")
      return
    }
    Log.info(Log.monitor, "monitor", "mic inactive, starting grace period")
    startGracePeriod()
  }

  private func startAutoRecording() {
    guard autoRecorder == nil else {
      Log.info(Log.monitor, "monitor", "startAutoRecording skipped: already recording")
      return
    }

    let useMic = micEnabled
    let appName = autoRecordingAppName ?? "Call"
    let recorder = AudioRecorder(
      bundleID: autoRecordingBundleID,
      appName: appName,
      micEnabled: useMic,
      saveDirectory: saveDirectory,
      onFailure: { [weak self] failure in
        Task { @MainActor [weak self] in
          self?.handleAutoRecorderFailure(failure)
        }
      },
      onAudioLevel: { [weak self] level in
        Task { @MainActor [weak self] in
          self?.audioLevel = level
        }
      },
      onLowDiskSpace: { [weak self] remaining in
        Task { @MainActor [weak self] in
          self?.handleLowDiskSpace(remaining)
        }
      }
    )

    autoRecorder = recorder
    Log.info(
      Log.monitor, "monitor", "starting auto-recording (call detected, app=\(appName))")

    Task {
      do {
        try await recorder.start()
        UserDefaults.standard.set(true, forKey: "audioRecordingGranted")
        permissionNeeded = false
        autoRestartCount = 0
        autoRestartWindowStart = nil
        isRecording = true
        currentAppName = appName
        recordingStartTime = Date()
        startElapsedTimer()
        notifyRecordingStarted(appName: appName)
      } catch {
        setError("Failed to start recording: \(error.localizedDescription)")
        if let recError = error as? RecorderError,
          case .permissionDenied = recError
        {
          permissionNeeded = true
        }
        autoRecorder = nil
        updateAutoState()
      }
    }
  }

  private func stopAutoRecording() {
    guard let recorder = autoRecorder else { return }
    let appName = autoRecordingAppName ?? "Call"
    autoRecorder = nil
    autoRecordingAppName = nil
    autoRecordingBundleID = nil
    Log.info(Log.monitor, "monitor", "stopping auto-recording (app=\(appName))")
    savingCount += 1
    isSaving = true
    Task {
      let url = await recorder.stop()
      savingCount -= 1
      isSaving = savingCount > 0
      if url != nil {
        notifyRecordingSaved(appName: appName)
      }
      updateAutoState()
    }
  }

  private func handleAutoRecorderFailure(_ failure: RecorderFailure) {
    guard let failedRecorder = autoRecorder else {
      Log.info(Log.monitor, "monitor", "handleAutoRecorderFailure skipped: recorder already nil")
      return
    }
    autoRecorder = nil
    stopElapsedTimer()
    cancelGracePeriod()

    savingCount += 1
    isSaving = true
    Task {
      _ = await failedRecorder.stop()
      savingCount -= 1
      isSaving = savingCount > 0
    }

    switch failure {
    case .permissionDenied:
      permissionNeeded = true
      notifyPermissionLost()
      autoRecordingAppName = nil
      autoRecordingBundleID = nil
      updateAutoState()
    case .systemStopped:
      if shouldAllowRestart(
        count: &autoRestartCount, windowStart: &autoRestartWindowStart)
      {
        Log.info(Log.monitor, "monitor", "auto-recording interrupted, restarting")
        startAutoRecording()
      } else {
        Log.error(Log.monitor, "monitor", "auto-recording restart limit exceeded")
        setError("Recording failed repeatedly")
        autoRecordingAppName = nil
        autoRecordingBundleID = nil
        updateAutoState()
      }
    case .lowDiskSpace:
      setError("Recording stopped - not enough disk space")
      autoRecordingAppName = nil
      autoRecordingBundleID = nil
      updateAutoState()
    case .other:
      setError("Recording interrupted")
      autoRecordingAppName = nil
      autoRecordingBundleID = nil
      updateAutoState()
    }
  }

  // MARK: - Grace Period

  private func startGracePeriod() {
    graceTask?.cancel()
    let period = gracePeriod
    graceTask = Task {
      let start = Date()
      while !Task.isCancelled {
        let elapsed = Date().timeIntervalSince(start)
        let remaining = period - elapsed
        if remaining <= 0 {
          graceCountdown = nil
          stopAutoRecording()
          return
        }
        graceCountdown = remaining
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  private func cancelGracePeriod() {
    graceTask?.cancel()
    graceTask = nil
    graceCountdown = nil
  }

  // MARK: - State

  private func updateAutoState() {
    guard !isManualRecording else { return }
    if autoRecorder != nil {
      isRecording = true
    } else {
      isRecording = false
      currentAppName = nil
      recordingStartTime = nil
      audioLevel = 0
      stopElapsedTimer()
    }
  }

  private func loadSettings() {
    let defaults = UserDefaults.standard
    autoRecord = defaults.object(forKey: "autoRecord") as? Bool ?? true
    gracePeriod = defaults.double(forKey: "gracePeriod").clamped(to: 5...60, default: 5)
    micEnabled = defaults.object(forKey: "micEnabled") as? Bool ?? true
    let path = defaults.string(forKey: "saveDirectoryPath") ?? defaultSaveDirectoryPath
    saveDirectory = URL(fileURLWithPath: path)
    notifyOnStart = defaults.object(forKey: "notifyOnStart") as? Bool ?? true
    notifyOnSaved = defaults.object(forKey: "notifyOnSaved") as? Bool ?? true
    notifyOnError = defaults.object(forKey: "notifyOnError") as? Bool ?? true
    micPermissionNeeded =
      micEnabled && AVCaptureDevice.authorizationStatus(for: .audio) != .authorized
  }

  // MARK: - Restart Rate Limiting

  private func shouldAllowRestart(
    count: inout Int, windowStart: inout Date?, max: Int = 3, window: TimeInterval = 30
  ) -> Bool {
    let now = Date()
    if let start = windowStart, now.timeIntervalSince(start) > window {
      count = 0
      windowStart = nil
    }
    if windowStart == nil { windowStart = now }
    count += 1
    return count <= max
  }

  // MARK: - Notifications

  private func notifyRecordingStarted(appName: String) {
    guard notifyOnStart else { return }
    hud.showRecordingStarted(appName: appName)
  }

  private func notifyRecordingSaved(appName: String) {
    guard notifyOnSaved else { return }
    hud.showRecordingSaved(appName: appName)
  }

  private func notifyError(message: String) {
    guard notifyOnError else { return }
    hud.showError(message: message)
  }

  /// Send system notification when audio recording permission is revoked.
  /// Used because the user may be focused on their call app and not see the menu bar.
  private func notifyPermissionLost() {
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
    Task {
      try? await UNUserNotificationCenter.current().add(request)
    }
  }
}

extension Double {
  fileprivate func clamped(to range: ClosedRange<Double>, default defaultValue: Double) -> Double {
    self == 0 ? defaultValue : min(max(self, range.lowerBound), range.upperBound)
  }
}
