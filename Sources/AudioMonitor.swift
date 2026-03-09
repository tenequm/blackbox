import AVFoundation
import AppKit
import CoreAudio
import Foundation
import ScreenCaptureKit

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
  private(set) var audioLevel: Float = 0
  private var savingCount = 0

  // Auto-recording triggered by mic detection
  private var autoRecorder: AudioRecorder?
  private var autoRecordingAppName: String?
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

  // Per-process mic detection (macOS 14.2+) - monitors which processes have active mic input.
  // @ObservationIgnored: internal CoreAudio bookkeeping, not UI state.
  // nonisolated(unsafe): deinit (nonisolated in Swift 6) must read these to remove
  // CoreAudio listeners and prevent dangling pointer callbacks. Thread safety: only
  // mutated on MainActor during normal operation; deinit is the final access point
  // where no other references exist. Class is @unchecked Sendable.
  @ObservationIgnored nonisolated(unsafe) private var monitoredProcessObjectIDs:
    Set<AudioObjectID> =
      []
  @ObservationIgnored nonisolated(unsafe) private var processListListenerRegistered = false
  private var micPollingTask: Task<Void, Never>?
  private var lastKnownMicRunning = false

  private let hud = RecordingHUD()

  // Safety net: CoreAudio listeners hold an Unmanaged.passUnretained(self) pointer.
  // If this object is deallocated with listeners still registered, the callback fires
  // into a dangling pointer - crash. stopMonitoring() handles the normal path;
  // deinit catches unexpected teardown (e.g. future refactors that break the lifecycle).
  //
  // deinit is nonisolated in Swift 6, so we inline the CoreAudio C calls directly
  // rather than calling the MainActor-isolated helper methods.
  deinit {
    let selfPtr = Unmanaged.passUnretained(self).toOpaque()
    var inputAddr = AudioObjectPropertyAddress(
      mSelector: kAudioProcessPropertyIsRunningInput,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    for id in monitoredProcessObjectIDs {
      AudioObjectRemovePropertyListener(id, &inputAddr, Self.processInputChangedProc, selfPtr)
    }
    if processListListenerRegistered {
      var procListAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )
      AudioObjectRemovePropertyListener(
        AudioObjectID(kAudioObjectSystemObject), &procListAddr, Self.processListChangedProc,
        selfPtr)
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

    if !skipPermissionRequests {
      Task {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
          await AVCaptureDevice.requestAccess(for: .audio)
        }
      }
    }

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
    removeAllProcessInputListeners()
    removeProcessListListener()
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
    notifyError(message: message)
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
      },
      onAudioLevel: { [weak self] level in
        Task { @MainActor [weak self] in
          self?.audioLevel = level
        }
      }
    )

    manualRecorder = recorder
    isManualRecording = true

    Task {
      do {
        try await recorder.start()
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
      updateAutoState()
    case .micFailed:
      setError("Microphone lost - recording continues without mic")
      startManualRecordingInternal(micOverride: false)
    case .systemStopped, .deviceChangeFailed, .other:
      if shouldAllowRestart(
        count: &manualRestartCount, windowStart: &manualRestartWindowStart)
      {
        setError("Recording interrupted - restarting...")
        startManualRecordingInternal()
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
      evaluateMicState()
    }
  }

  // MARK: - Per-Process Mic Detection (macOS 14.2+)

  private func setupMicMonitoring() {
    addProcessListListener()
    updateProcessInputListeners()

    let micUsers = Self.externalMicUsers()
    lastKnownMicRunning = !micUsers.isEmpty
    Log.info(
      Log.monitor, "monitor",
      "mic monitoring started: \(monitoredProcessObjectIDs.count) audio processes, externalMicUsers=\(micUsers.count)"
    )

    // Check current state in case app starts mid-call
    if let first = micUsers.first {
      handleMicBecameActive(appBundleID: first.bundleID)
    }

    // Polling fallback: CoreAudio listener may not fire for all audio pipelines
    micPollingTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(3))
        guard let self else { return }
        self.evaluateMicState()
      }
    }
  }

  // MARK: - Process List Listener

  private func addProcessListListener() {
    guard !processListListenerRegistered else { return }
    let selfPtr = Unmanaged.passUnretained(self).toOpaque()
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyProcessObjectList,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectAddPropertyListener(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      Self.processListChangedProc,
      selfPtr
    )
    if status == noErr {
      processListListenerRegistered = true
    } else {
      Log.error(Log.monitor, "monitor", "failed to register process list listener: \(status)")
    }
  }

  private func removeProcessListListener() {
    guard processListListenerRegistered else { return }
    let selfPtr = Unmanaged.passUnretained(self).toOpaque()
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyProcessObjectList,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectRemovePropertyListener(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      Self.processListChangedProc,
      selfPtr
    )
    processListListenerRegistered = false
  }

  // MARK: - Per-Process Input Listeners

  private func updateProcessInputListeners() {
    let allProcesses = Set(Self.allAudioProcessObjects())
    let current = monitoredProcessObjectIDs
    let toAdd = allProcesses.subtracting(current)
    let toRemove = current.subtracting(allProcesses)

    let selfPtr = Unmanaged.passUnretained(self).toOpaque()
    var inputAddr = AudioObjectPropertyAddress(
      mSelector: kAudioProcessPropertyIsRunningInput,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    for id in toRemove {
      AudioObjectRemovePropertyListener(id, &inputAddr, Self.processInputChangedProc, selfPtr)
      monitoredProcessObjectIDs.remove(id)
    }

    for id in toAdd {
      let status = AudioObjectAddPropertyListener(
        id, &inputAddr, Self.processInputChangedProc, selfPtr)
      if status == noErr {
        monitoredProcessObjectIDs.insert(id)
      }
    }

    if !toAdd.isEmpty || !toRemove.isEmpty {
      Log.info(
        Log.monitor, "monitor",
        "process listeners updated: monitoring \(monitoredProcessObjectIDs.count) processes (added \(toAdd.count), removed \(toRemove.count))"
      )
    }
  }

  private func removeAllProcessInputListeners() {
    let selfPtr = Unmanaged.passUnretained(self).toOpaque()
    var inputAddr = AudioObjectPropertyAddress(
      mSelector: kAudioProcessPropertyIsRunningInput,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    for id in monitoredProcessObjectIDs {
      AudioObjectRemovePropertyListener(id, &inputAddr, Self.processInputChangedProc, selfPtr)
    }
    monitoredProcessObjectIDs.removeAll()
  }

  // MARK: - Process Query Functions

  /// Enumerate all audio process objects registered with CoreAudio.
  nonisolated private static func allAudioProcessObjects() -> [AudioObjectID] {
    var propSize: UInt32 = 0
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyProcessObjectList,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    guard
      AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &propSize) == noErr,
      propSize > 0
    else { return [] }

    let count = Int(propSize) / MemoryLayout<AudioObjectID>.size
    var objects = [AudioObjectID](repeating: 0, count: count)
    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &propSize, &objects) == noErr
    else { return [] }
    return objects
  }

  /// Get the PID for an AudioProcess object.
  nonisolated private static func processPID(for objectID: AudioObjectID) -> pid_t? {
    var pid: pid_t = 0
    var size = UInt32(MemoryLayout<pid_t>.size)
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioProcessPropertyPID,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &pid) == noErr else {
      return nil
    }
    return pid
  }

  /// Get the bundle ID for an AudioProcess object.
  nonisolated private static func processBundleID(for objectID: AudioObjectID) -> String? {
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioProcessPropertyBundleID,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    // CFString is a reference type - can't form UnsafeMutableRawPointer to it directly.
    // Allocate a raw buffer for the CFStringRef pointer instead.
    let buf = UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: 1)
    defer { buf.deallocate() }
    buf.initialize(to: nil)
    var size = UInt32(MemoryLayout<UnsafeRawPointer?>.size)
    guard AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, buf) == noErr,
      let raw = buf.pointee
    else {
      return nil
    }
    return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
  }

  /// Check if an AudioProcess object has active microphone input.
  nonisolated private static func isProcessUsingMicInput(_ objectID: AudioObjectID) -> Bool {
    var isRunning: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioProcessPropertyIsRunningInput,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &isRunning)
    return isRunning != 0
  }

  /// Returns all external processes (not us, not SCK helpers) that have active mic input.
  /// This is the core detection function - filters out our own PID and ScreenCaptureKit
  /// XPC service processes so we only see OTHER apps' mic usage.
  nonisolated private static func externalMicUsers()
    -> [(processObjectID: AudioObjectID, pid: pid_t, bundleID: String?)]
  {
    let myPID = ProcessInfo.processInfo.processIdentifier
    var result: [(processObjectID: AudioObjectID, pid: pid_t, bundleID: String?)] = []

    for objectID in allAudioProcessObjects() {
      guard isProcessUsingMicInput(objectID) else { continue }
      guard let pid = processPID(for: objectID) else { continue }

      // Filter out our own process
      if pid == myPID { continue }

      // Filter out ScreenCaptureKit XPC helpers (they open the mic on our behalf)
      let bundleID = processBundleID(for: objectID)
      if let bid = bundleID,
        bid.hasPrefix("com.apple.screencapturekit")
          || bid.hasPrefix("com.apple.ScreenCaptureKit")
          || bid.hasPrefix("com.apple.replayd")
      {
        continue
      }

      result.append((processObjectID: objectID, pid: pid, bundleID: bundleID))
    }
    return result
  }

  // MARK: - Mic State Evaluation

  /// Re-evaluate mic state by checking which external processes have active mic input.
  /// Called from listeners and polling fallback.
  private func evaluateMicState() {
    let micUsers = Self.externalMicUsers()
    let running = !micUsers.isEmpty

    if running != lastKnownMicRunning {
      Log.info(
        Log.monitor, "monitor",
        "mic state changed: externalMicUsers=\(micUsers.count), running=\(running)")
      lastKnownMicRunning = running
      if running {
        handleMicBecameActive(appBundleID: micUsers.first?.bundleID)
      } else {
        handleMicBecameInactive()
      }
    }
  }

  func handleProcessListChanged() {
    Log.info(Log.monitor, "monitor", "audio process list changed")
    updateProcessInputListeners()
    evaluateMicState()
  }

  func handleProcessInputChange() {
    evaluateMicState()
  }

  /// Resolve a bundle ID to a human-readable app name.
  private static func resolveAppName(bundleID: String?) -> String {
    guard let bundleID else { return "Call" }
    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
      let name = app.localizedName
    {
      return name
    }
    // Fallback: extract last component of bundle ID (e.g. "com.zoom.us" -> "zoom")
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

    // Check screen recording permission
    if !CGPreflightScreenCaptureAccess() {
      Log.info(
        Log.monitor, "monitor", "handleMicBecameActive blocked: screen recording permission denied")
      permissionNeeded = true
      return
    }
    permissionNeeded = false

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

  private func startAutoRecording(micOverride: Bool? = nil) {
    guard autoRecorder == nil else {
      Log.info(Log.monitor, "monitor", "startAutoRecording skipped: already recording")
      return
    }

    let useMic = micOverride ?? micEnabled
    let appName = autoRecordingAppName ?? "Call"
    let recorder = AudioRecorder(
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
      }
    )

    autoRecorder = recorder
    Log.info(
      Log.monitor, "monitor", "starting auto-recording (mic activity detected, app=\(appName))")

    Task {
      do {
        try await recorder.start()
        autoRestartCount = 0
        autoRestartWindowStart = nil
        isRecording = true
        currentAppName = appName
        recordingStartTime = Date()
        startElapsedTimer()
        notifyRecordingStarted(appName: appName)
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
    let appName = autoRecordingAppName ?? "Call"
    autoRecorder = nil
    autoRecordingAppName = nil
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
      autoRecordingAppName = nil
      updateAutoState()
    case .systemStopped, .deviceChangeFailed:
      if shouldAllowRestart(
        count: &autoRestartCount, windowStart: &autoRestartWindowStart)
      {
        Log.info(Log.monitor, "monitor", "auto-recording interrupted, restarting")
        startAutoRecording()
      } else {
        Log.error(Log.monitor, "monitor", "auto-recording restart limit exceeded")
        setError("Recording failed repeatedly")
        autoRecordingAppName = nil
        updateAutoState()
      }
    case .micFailed:
      Log.info(Log.monitor, "monitor", "auto-recording mic failed, restarting without mic")
      startAutoRecording(micOverride: false)
    case .other:
      setError("Recording interrupted")
      autoRecordingAppName = nil
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

  // MARK: - Notifications (HUD-based, switchable to system notifications later)

  private func notifyRecordingStarted(appName: String) {
    guard notifyOnStart else { return }
    hud.showRecordingStarted(appName: appName, bundleID: nil)
  }

  private func notifyRecordingSaved(appName: String) {
    guard notifyOnSaved else { return }
    hud.showRecordingSaved(appName: appName)
  }

  private func notifyError(message: String) {
    guard notifyOnError else { return }
    hud.showError(message: message)
  }
}

// MARK: - CoreAudio Callbacks

extension AudioMonitor {
  nonisolated static let processListChangedProc: AudioObjectPropertyListenerProc = {
    _, _, _, clientData in
    guard let clientData else { return noErr }
    let monitor = Unmanaged<AudioMonitor>.fromOpaque(clientData).takeUnretainedValue()
    Task { @MainActor in
      monitor.handleProcessListChanged()
    }
    return noErr
  }

  nonisolated static let processInputChangedProc: AudioObjectPropertyListenerProc = {
    _, _, _, clientData in
    guard let clientData else { return noErr }
    let monitor = Unmanaged<AudioMonitor>.fromOpaque(clientData).takeUnretainedValue()
    Task { @MainActor in
      monitor.handleProcessInputChange()
    }
    return noErr
  }
}

extension Double {
  fileprivate func clamped(to range: ClosedRange<Double>, default defaultValue: Double) -> Double {
    self == 0 ? defaultValue : min(max(self, range.lowerBound), range.upperBound)
  }
}
