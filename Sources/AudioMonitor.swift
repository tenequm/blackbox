import AVFoundation
import AppKit
import CoreAudio
import Foundation
import ScreenCaptureKit
import UserNotifications

@Observable
final class AudioMonitor: @unchecked Sendable {
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
  private var savingCount = 0

  // Auto-recording triggered by mic detection
  private var autoRecorder: AudioRecorder?
  // Manual recording triggered by user
  private var manualRecorder: AudioRecorder?

  private var settingsTask: Task<Void, Never>?
  private var elapsedTimer: Timer?
  private var graceTask: Task<Void, Never>?

  // CoreAudio mic detection
  private var currentInputDeviceID: AudioObjectID = kAudioObjectUnknown
  private var micListenerRegistered = false
  private var defaultDeviceListenerRegistered = false
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
    guard settingsTask == nil else { return }
    loadSettings()

    if !CGPreflightScreenCaptureAccess() {
      Log.info(Log.monitor, "monitor", "screen recording permission not granted")
      permissionNeeded = true
    }

    UNUserNotificationCenter.current().delegate = notificationDelegate

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

    let revealAction = UNNotificationAction(identifier: "reveal", title: "Reveal in Finder")
    let playAction = UNNotificationAction(identifier: "play", title: "Play")
    let category = UNNotificationCategory(
      identifier: "recordingSaved", actions: [revealAction, playAction], intentIdentifiers: [])
    UNUserNotificationCenter.current().setNotificationCategories([category])

    // Start mic activity monitoring
    setupMicMonitoring()

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
    removeMicActivityListener()
    removeDefaultDeviceListener()
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
        startElapsedTimer()
        hud.showRecordingStarted(appName: "Manual recording", bundleID: nil)
      } catch {
        setError("Failed to start recording: \(error.localizedDescription)")
        manualRecorder = nil
        isManualRecording = false
        updateAutoState()
      }
    }
  }

  private func handleManualRecorderFailure(_ failure: RecorderFailure) {
    guard let failedRecorder = manualRecorder else { return }
    let appName = currentAppName ?? failedRecorder.appName

    manualRecorder = nil
    isManualRecording = false
    stopElapsedTimer()

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

    switch failure {
    case .permissionDenied:
      permissionNeeded = true
      updateAutoState()
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
    stopElapsedTimer()
    savingCount += 1
    isSaving = true
    Task {
      let url = await recorder.stop()
      savingCount -= 1
      isSaving = savingCount > 0
      if let url {
        hud.showRecordingSaved(appName: appName, fileName: url.lastPathComponent, fileURL: url)
        if notifyOnSaved {
          postRecordingSavedNotification(appName: appName, fileURL: url)
        }
      }
      updateAutoState()
    }
  }

  // MARK: - Mic Activity Detection

  private func setupMicMonitoring() {
    addDefaultDeviceListener()
    updateMicActivityListener()

    let running = isMicRunning()
    lastKnownMicRunning = running
    Log.info(
      Log.monitor, "monitor",
      "mic monitoring started: device=\(currentInputDeviceID), running=\(running), listener=\(micListenerRegistered)"
    )

    // Check current state in case app starts mid-call
    if running { handleMicBecameActive() }

    // Polling fallback: CoreAudio listener may not fire for all audio pipelines
    micPollingTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(3))
        guard let self else { return }
        let running = self.isMicRunning()
        if running != self.lastKnownMicRunning {
          Log.info(
            Log.monitor, "monitor", "mic poll detected change: running=\(running)")
          self.lastKnownMicRunning = running
          if running {
            self.handleMicBecameActive()
          } else {
            self.handleMicBecameInactive()
          }
        }
      }
    }
  }

  private func addDefaultDeviceListener() {
    guard !defaultDeviceListenerRegistered else { return }
    let selfPtr = Unmanaged.passUnretained(self).toOpaque()
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectAddPropertyListener(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      Self.defaultDeviceChangedProc,
      selfPtr
    )
    if status == noErr {
      defaultDeviceListenerRegistered = true
      Log.info(Log.monitor, "monitor", "default device listener registered")
    } else {
      Log.error(Log.monitor, "monitor", "failed to register default device listener: \(status)")
    }
  }

  private func removeDefaultDeviceListener() {
    guard defaultDeviceListenerRegistered else { return }
    let selfPtr = Unmanaged.passUnretained(self).toOpaque()
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectRemovePropertyListener(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      Self.defaultDeviceChangedProc,
      selfPtr
    )
    defaultDeviceListenerRegistered = false
  }

  private func updateMicActivityListener() {
    removeMicActivityListener()

    var deviceID = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address, 0, nil, &size, &deviceID
    )

    guard deviceID != kAudioObjectUnknown else {
      Log.info(Log.monitor, "monitor", "no default input device found")
      currentInputDeviceID = kAudioObjectUnknown
      return
    }

    currentInputDeviceID = deviceID
    let selfPtr = Unmanaged.passUnretained(self).toOpaque()
    var runningAddress = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectAddPropertyListener(
      deviceID, &runningAddress,
      Self.micActivityChangedProc,
      selfPtr
    )
    if status == noErr {
      micListenerRegistered = true
      Log.info(Log.monitor, "monitor", "mic activity listener registered on device \(deviceID)")
    } else {
      Log.error(Log.monitor, "monitor", "failed to register mic activity listener: \(status)")
    }
  }

  private func removeMicActivityListener() {
    guard micListenerRegistered, currentInputDeviceID != kAudioObjectUnknown else { return }
    let selfPtr = Unmanaged.passUnretained(self).toOpaque()
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectRemovePropertyListener(
      currentInputDeviceID, &address,
      Self.micActivityChangedProc,
      selfPtr
    )
    micListenerRegistered = false
  }

  private func isMicRunning() -> Bool {
    guard currentInputDeviceID != kAudioObjectUnknown else { return false }
    var isRunning: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectGetPropertyData(
      currentInputDeviceID, &address, 0, nil, &size, &isRunning
    )
    return isRunning != 0
  }

  private func checkMicState() {
    if isMicRunning() {
      handleMicBecameActive()
    }
  }

  func handleMicActivityChange() {
    let running = isMicRunning()
    Log.info(Log.monitor, "monitor", "CoreAudio listener fired: running=\(running)")
    lastKnownMicRunning = running
    if running {
      handleMicBecameActive()
    } else {
      handleMicBecameInactive()
    }
  }

  func handleDefaultDeviceChanged() {
    Log.info(Log.monitor, "monitor", "default input device changed")
    updateMicActivityListener()
    checkMicState()
  }

  // MARK: - Auto Recording

  private func handleMicBecameActive() {
    cancelGracePeriod()

    guard autoRecord, !isRecording, !isManualRecording else { return }

    // Check screen recording permission
    if !CGPreflightScreenCaptureAccess() {
      permissionNeeded = true
      return
    }
    permissionNeeded = false

    loadSettings()
    startAutoRecording()
  }

  private func handleMicBecameInactive() {
    guard autoRecorder != nil else { return }
    Log.info(Log.monitor, "monitor", "mic inactive, starting grace period")
    startGracePeriod()
  }

  private func startAutoRecording() {
    guard autoRecorder == nil else { return }

    let recorder = AudioRecorder(
      appName: "Call",
      micEnabled: false,  // System audio only - keeps mic detection clean
      saveDirectory: saveDirectory,
      onFailure: { [weak self] failure in
        Task { @MainActor [weak self] in
          self?.handleAutoRecorderFailure(failure)
        }
      }
    )

    autoRecorder = recorder
    Log.info(Log.monitor, "monitor", "starting auto-recording (mic activity detected)")

    Task {
      do {
        try await recorder.start()
        isRecording = true
        currentAppName = "Call"
        recordingStartTime = Date()
        startElapsedTimer()
        hud.showRecordingStarted(appName: "Call", bundleID: nil)
        if notifyOnStart { postRecordingStartedNotification(appName: "Call") }
      } catch {
        setError("Failed to start recording: \(error.localizedDescription)")
        if (error as NSError).domain == "com.apple.ScreenCaptureKit.SCStreamError",
          (error as NSError).code == -3801
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
    autoRecorder = nil
    Log.info(Log.monitor, "monitor", "stopping auto-recording")
    savingCount += 1
    isSaving = true
    Task {
      let url = await recorder.stop()
      savingCount -= 1
      isSaving = savingCount > 0
      if let url {
        hud.showRecordingSaved(appName: "Call", fileName: url.lastPathComponent, fileURL: url)
        if notifyOnSaved {
          postRecordingSavedNotification(appName: "Call", fileURL: url)
        }
      }
      updateAutoState()
    }
  }

  private func handleAutoRecorderFailure(_ failure: RecorderFailure) {
    guard let failedRecorder = autoRecorder else { return }
    autoRecorder = nil
    stopElapsedTimer()
    cancelGracePeriod()

    savingCount += 1
    isSaving = true
    Task {
      let url = await failedRecorder.stop()
      savingCount -= 1
      isSaving = savingCount > 0
      if let url, notifyOnSaved {
        postRecordingSavedNotification(appName: "Call", fileURL: url)
      }
    }

    switch failure {
    case .permissionDenied:
      permissionNeeded = true
      updateAutoState()
    case .systemStopped, .deviceChangeFailed:
      Log.info(Log.monitor, "monitor", "auto-recording interrupted, restarting")
      startAutoRecording()
    case .micFailed, .other:
      setError("Recording interrupted")
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
}

// MARK: - CoreAudio Callbacks

extension AudioMonitor {
  nonisolated static let micActivityChangedProc: AudioObjectPropertyListenerProc = {
    _, _, _, clientData in
    guard let clientData else { return noErr }
    let monitor = Unmanaged<AudioMonitor>.fromOpaque(clientData).takeUnretainedValue()
    Task { @MainActor in
      monitor.handleMicActivityChange()
    }
    return noErr
  }

  nonisolated static let defaultDeviceChangedProc: AudioObjectPropertyListenerProc = {
    _, _, _, clientData in
    guard let clientData else { return noErr }
    let monitor = Unmanaged<AudioMonitor>.fromOpaque(clientData).takeUnretainedValue()
    Task { @MainActor in
      monitor.handleDefaultDeviceChanged()
    }
    return noErr
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

extension Double {
  fileprivate func clamped(to range: ClosedRange<Double>, default defaultValue: Double) -> Double {
    self == 0 ? defaultValue : min(max(self, range.lowerBound), range.upperBound)
  }
}
