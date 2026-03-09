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

  // CoreAudio mic detection - monitors ALL input devices.
  // @ObservationIgnored: these are internal CoreAudio bookkeeping, not UI state.
  // nonisolated(unsafe): deinit (nonisolated in Swift 6) must read these to remove
  // CoreAudio listeners and prevent dangling pointer callbacks. Thread safety: only
  // mutated on MainActor during normal operation; deinit is the final access point
  // where no other references exist. Class is @unchecked Sendable.
  @ObservationIgnored nonisolated(unsafe) private var monitoredDeviceIDs: Set<AudioObjectID> = []
  @ObservationIgnored nonisolated(unsafe) private var deviceListListenerRegistered = false
  private var micPollingTask: Task<Void, Never>?
  private var lastKnownMicRunning = false

  private let hud = RecordingHUD()

  // Safety net: CoreAudio listeners hold an Unmanaged.passUnretained(self) pointer.
  // If this object is deallocated with listeners still registered, the callback fires
  // into a dangling pointer → crash. stopMonitoring() handles the normal path;
  // deinit catches unexpected teardown (e.g. future refactors that break the lifecycle).
  //
  // deinit is nonisolated in Swift 6, so we inline the CoreAudio C calls directly
  // rather than calling the MainActor-isolated helper methods.
  deinit {
    let selfPtr = Unmanaged.passUnretained(self).toOpaque()
    var runAddr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    for id in monitoredDeviceIDs {
      AudioObjectRemovePropertyListener(id, &runAddr, Self.micActivityChangedProc, selfPtr)
    }
    if deviceListListenerRegistered {
      var devAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )
      AudioObjectRemovePropertyListener(
        AudioObjectID(kAudioObjectSystemObject), &devAddr, Self.deviceListChangedProc, selfPtr)
    }
  }

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
    removeAllMicActivityListeners()
    removeDeviceListListener()
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
    guard manualRecorder == nil else {
      Log.info(Log.monitor, "monitor", "startManualRecording skipped: already recording")
      return
    }

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
    guard let failedRecorder = manualRecorder else {
      Log.info(Log.monitor, "monitor", "handleManualRecorderFailure skipped: recorder already nil")
      return
    }
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
    addDeviceListListener()
    updateMicActivityListeners()

    let running = isAnyInputDeviceRunning()
    lastKnownMicRunning = running
    Log.info(
      Log.monitor, "monitor",
      "mic monitoring started: \(monitoredDeviceIDs.count) input devices, running=\(running)"
    )

    // Check current state in case app starts mid-call
    if running { handleMicBecameActive() }

    // Polling fallback: CoreAudio listener may not fire for all audio pipelines
    micPollingTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(3))
        guard let self else { return }
        let running = self.isAnyInputDeviceRunning()
        if running != self.lastKnownMicRunning {
          Log.info(Log.monitor, "monitor", "mic poll detected change: running=\(running)")
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

  // MARK: - Device List Listener (hot-plug)

  private func addDeviceListListener() {
    guard !deviceListListenerRegistered else { return }
    let selfPtr = Unmanaged.passUnretained(self).toOpaque()
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectAddPropertyListener(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      Self.deviceListChangedProc,
      selfPtr
    )
    if status == noErr {
      deviceListListenerRegistered = true
    } else {
      Log.error(Log.monitor, "monitor", "failed to register device list listener: \(status)")
    }
  }

  private func removeDeviceListListener() {
    guard deviceListListenerRegistered else { return }
    let selfPtr = Unmanaged.passUnretained(self).toOpaque()
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectRemovePropertyListener(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      Self.deviceListChangedProc,
      selfPtr
    )
    deviceListListenerRegistered = false
  }

  // MARK: - Per-Device Activity Listeners

  private func updateMicActivityListeners() {
    let inputDevices = Self.allInputDeviceIDs()
    let current = monitoredDeviceIDs
    let toAdd = inputDevices.subtracting(current)
    let toRemove = current.subtracting(inputDevices)

    let selfPtr = Unmanaged.passUnretained(self).toOpaque()
    var runAddr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    for id in toRemove {
      AudioObjectRemovePropertyListener(id, &runAddr, Self.micActivityChangedProc, selfPtr)
      monitoredDeviceIDs.remove(id)
    }

    for id in toAdd {
      let status = AudioObjectAddPropertyListener(
        id, &runAddr, Self.micActivityChangedProc, selfPtr)
      if status == noErr {
        monitoredDeviceIDs.insert(id)
      }
    }

    if !toAdd.isEmpty || !toRemove.isEmpty {
      Log.info(
        Log.monitor, "monitor",
        "mic listeners updated: monitoring \(monitoredDeviceIDs.count) devices (added \(toAdd.count), removed \(toRemove.count))"
      )
    }
  }

  private func removeAllMicActivityListeners() {
    let selfPtr = Unmanaged.passUnretained(self).toOpaque()
    var runAddr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    for id in monitoredDeviceIDs {
      AudioObjectRemovePropertyListener(id, &runAddr, Self.micActivityChangedProc, selfPtr)
    }
    monitoredDeviceIDs.removeAll()
  }

  /// Returns true if ANY input device has its audio engine running.
  private func isAnyInputDeviceRunning() -> Bool {
    var runAddr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    for id in monitoredDeviceIDs {
      var isRunning: UInt32 = 0
      var size = UInt32(MemoryLayout<UInt32>.size)
      AudioObjectGetPropertyData(id, &runAddr, 0, nil, &size, &isRunning)
      if isRunning != 0 { return true }
    }
    return false
  }

  /// Enumerate all physical audio devices that have input channels.
  /// Excludes virtual and aggregate devices to avoid false positives.
  nonisolated private static func allInputDeviceIDs() -> Set<AudioObjectID> {
    var propSize: UInt32 = 0
    var devAddr = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    guard
      AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &devAddr, 0, nil, &propSize) == noErr,
      propSize > 0
    else { return [] }

    let count = Int(propSize) / MemoryLayout<AudioObjectID>.size
    var devices = [AudioObjectID](repeating: 0, count: count)
    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &devAddr, 0, nil, &propSize, &devices) == noErr
    else { return [] }

    var inputAddr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamConfiguration,
      mScope: kAudioObjectPropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain
    )
    var transportAddr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyTransportType,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    var result: Set<AudioObjectID> = []
    for id in devices {
      // Skip virtual and aggregate devices
      var transport: UInt32 = 0
      var transportSize = UInt32(MemoryLayout<UInt32>.size)
      AudioObjectGetPropertyData(id, &transportAddr, 0, nil, &transportSize, &transport)
      if transport == kAudioDeviceTransportTypeVirtual
        || transport == kAudioDeviceTransportTypeAggregate
      {
        continue
      }

      // Check for input channels.
      // IMPORTANT: AudioBufferList is a variable-length C struct - mBuffers is a
      // flexible array member. Allocating `UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)`
      // only reserves space for ONE AudioBuffer. Multi-channel pro interfaces may have
      // multiple buffers, causing AudioObjectGetPropertyData to write past the allocation
      // (heap overflow / UB). Always allocate exactly `bufSize` bytes from GetPropertyDataSize.
      var bufSize: UInt32 = 0
      guard AudioObjectGetPropertyDataSize(id, &inputAddr, 0, nil, &bufSize) == noErr,
        bufSize > 0
      else { continue }
      let rawBuf = UnsafeMutableRawPointer.allocate(
        byteCount: Int(bufSize), alignment: MemoryLayout<AudioBufferList>.alignment)
      defer { rawBuf.deallocate() }
      let bufferList = rawBuf.bindMemory(to: AudioBufferList.self, capacity: 1)
      guard AudioObjectGetPropertyData(id, &inputAddr, 0, nil, &bufSize, bufferList) == noErr
      else { continue }
      if bufferList.pointee.mNumberBuffers > 0
        && bufferList.pointee.mBuffers.mNumberChannels > 0
      {
        result.insert(id)
      }
    }
    return result
  }

  func handleMicActivityChange() {
    let running = isAnyInputDeviceRunning()
    Log.info(Log.monitor, "monitor", "CoreAudio listener fired: running=\(running)")
    lastKnownMicRunning = running
    if running {
      handleMicBecameActive()
    } else {
      handleMicBecameInactive()
    }
  }

  func handleDeviceListChanged() {
    Log.info(Log.monitor, "monitor", "audio device list changed")
    updateMicActivityListeners()
    if isAnyInputDeviceRunning() {
      handleMicBecameActive()
    }
  }

  // MARK: - Auto Recording

  private func handleMicBecameActive() {
    cancelGracePeriod()

    guard autoRecord, !isRecording, !isManualRecording else {
      Log.info(
        Log.monitor, "monitor",
        "handleMicBecameActive skipped: autoRecord=\(autoRecord), isRecording=\(isRecording), isManualRecording=\(isManualRecording)"
      )
      return
    }

    // Check screen recording permission
    if !CGPreflightScreenCaptureAccess() {
      Log.info(
        Log.monitor, "monitor", "handleMicBecameActive blocked: screen recording permission denied")
      permissionNeeded = true
      return
    }
    permissionNeeded = false

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

  nonisolated static let deviceListChangedProc: AudioObjectPropertyListenerProc = {
    _, _, _, clientData in
    guard let clientData else { return noErr }
    let monitor = Unmanaged<AudioMonitor>.fromOpaque(clientData).takeUnretainedValue()
    Task { @MainActor in
      monitor.handleDeviceListChanged()
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
