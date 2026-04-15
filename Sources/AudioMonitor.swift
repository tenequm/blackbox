import AVFoundation
import AppKit

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
  private(set) var lastSavedRecordingURL: URL?
  private var savingCount = 0

  // Auto-recording triggered by call detection
  private var autoRecorder: (any RecorderSession)?
  private var autoRecordingAppName: String?
  private var autoRecordingBundleID: String?
  // Manual recording triggered by user
  private var manualRecorder: (any RecorderSession)?

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
  private var consecutiveInactivePolls = 0
  private var continuityCooldownUntil: Date?
  @ObservationIgnored private let dependencies: AudioMonitorDependencies

  // Settings
  var autoRecord: Bool = true
  var gracePeriod: TimeInterval = 5
  var micEnabled: Bool = true
  var saveDirectory: URL = URL(fileURLWithPath: defaultSaveDirectoryPath)
  var notifyOnStart: Bool = true
  var notifyOnSaved: Bool = true
  var notifyOnError: Bool = true

  private var errorGeneration = 0

  init(dependencies: AudioMonitorDependencies = .live) {
    self.dependencies = dependencies
  }

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
      Task { @MainActor [weak self] in
        guard let self else { return }
        await self.dependencies.requestMicrophoneAccessIfNeeded()
      }
    }

    // Start call detection polling
    setupCallDetection()

    // Periodically reload settings
    settingsTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        await self.dependencies.sleep(.seconds(5))
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
      _ = await recorder.stop()
      autoRecorder = nil
    }

    if let recorder = manualRecorder {
      _ = await recorder.stop()
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
    Task { @MainActor [weak self] in
      guard let self else { return }
      await self.dependencies.sleep(.seconds(10))
      if self.errorGeneration == gen { self.errorMessage = nil }
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
    let total = max(0, Int(dependencies.now().timeIntervalSince(start)))
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    formattedElapsed =
      h > 0
      ? String(format: "%d:%02d:%02d", h, m, s)
      : String(format: "%d:%02d", m, s)
  }

  // MARK: - Manual Recording

  func startManualRecording(resetRestartBudget: Bool = true) {
    guard manualRecorder == nil else {
      Log.info(Log.monitor, "monitor", "startManualRecording skipped: already recording")
      return
    }

    if resetRestartBudget {
      manualRestartCount = 0
      manualRestartWindowStart = nil
    }

    let useMic = micEnabled
    lastSavedRecordingURL = nil
    let recorder = dependencies.recorderFactory.makeRecorder(
      configuration: RecorderSessionConfiguration(
        bundleID: nil,
        appName: "Manual recording",
        micEnabled: useMic,
        saveDirectory: saveDirectory,
        isManualRecording: true
      ),
      onFailure: makeFailureHandler(isManual: true),
      onAudioLevel: makeAudioLevelHandler(),
      onLowDiskSpace: makeLowDiskSpaceHandler(),
      onContinuityEvent: makeContinuityHandler()
    )

    manualRecorder = recorder
    isManualRecording = true

    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await recorder.start()
        self.dependencies.saveAudioRecordingGranted()
        self.permissionNeeded = false
        self.recordingStartTime = self.dependencies.now()
        self.currentAppName = "Manual recording"
        self.isRecording = true
        self.startElapsedTimer()
        self.notifyRecordingStarted(appName: "Manual recording")
      } catch {
        self.setError("Failed to start recording: \(error.localizedDescription)")
        self.manualRecorder = nil
        self.isManualRecording = false
        self.updateAutoState()
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
        startManualRecording(resetRestartBudget: false)
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
        lastSavedRecordingURL = url
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
    let callers = dependencies.findActiveCallingProcesses()
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
        guard let self else { return }
        await self.dependencies.sleep(.seconds(3))
        self.evaluateCallState()
      }
    }
  }

  // MARK: - Call State Evaluation

  /// Re-evaluate call state by checking which external processes have active calls.
  /// Called from polling loop every 3 seconds.
  private func evaluateCallState() {
    let callers = dependencies.findActiveCallingProcesses()
    let running = !callers.isEmpty

    if running {
      consecutiveInactivePolls = 0
      continuityCooldownUntil = nil
      if running != lastKnownMicRunning {
        Log.info(
          Log.monitor, "monitor",
          "call state changed: activeCallers=\(callers.count), running=\(running)")
        lastKnownMicRunning = true
        let bundleID = callers.count == 1 ? callers.first ?? nil : nil
        handleMicBecameActive(appBundleID: bundleID)
      } else if autoRecord, autoRecorder == nil, !isRecording, !isManualRecording {
        Log.info(Log.monitor, "monitor", "retrying auto-recording for active call")
        handleMicBecameActive(appBundleID: callers.first ?? nil)
      }
      return
    }

    if running != lastKnownMicRunning {
      Log.info(
        Log.monitor, "monitor",
        "call state changed: activeCallers=\(callers.count), running=\(running)")
      lastKnownMicRunning = running
    }

    guard autoRecorder != nil else { return }

    if shouldSuppressInactiveStop() {
      Log.info(Log.monitor, "monitor", "inactive poll ignored during continuity cooldown")
      return
    }

    consecutiveInactivePolls += 1
    guard consecutiveInactivePolls >= 2 else {
      Log.info(Log.monitor, "monitor", "inactive poll threshold not reached yet")
      return
    }

    handleMicBecameInactive()
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
    consecutiveInactivePolls = 0

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
    guard graceTask == nil else { return }

    Log.info(Log.monitor, "monitor", "mic inactive, starting grace period")
    let period = gracePeriod
    graceTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let start = self.dependencies.now()
      while !Task.isCancelled {
        let remaining = period - self.dependencies.now().timeIntervalSince(start)
        if remaining <= 0 {
          self.graceCountdown = nil
          self.stopAutoRecording()
          return
        }
        self.graceCountdown = remaining
        await self.dependencies.sleep(.seconds(1))
      }
    }
  }

  private func handleRecorderContinuityEvent(_ event: RecorderContinuityEvent) {
    let now = dependencies.now()
    continuityCooldownUntil = now.addingTimeInterval(max(gracePeriod, 8))
    consecutiveInactivePolls = 0
    cancelGracePeriod()
    Log.info(Log.monitor, "monitor", "continuity event observed: \(String(describing: event))")
  }

  private func shouldSuppressInactiveStop() -> Bool {
    guard let continuityCooldownUntil else { return false }
    if continuityCooldownUntil > dependencies.now() {
      return true
    }
    self.continuityCooldownUntil = nil
    return false
  }

  private func startAutoRecording(resetRestartBudget: Bool = true) {
    guard autoRecorder == nil else {
      Log.info(Log.monitor, "monitor", "startAutoRecording skipped: already recording")
      return
    }

    if resetRestartBudget {
      autoRestartCount = 0
      autoRestartWindowStart = nil
    }

    let useMic = micEnabled
    let appName = autoRecordingAppName ?? "Call"
    lastSavedRecordingURL = nil
    let recorder = dependencies.recorderFactory.makeRecorder(
      configuration: RecorderSessionConfiguration(
        bundleID: autoRecordingBundleID,
        appName: appName,
        micEnabled: useMic,
        saveDirectory: saveDirectory,
        isManualRecording: false
      ),
      onFailure: makeFailureHandler(isManual: false),
      onAudioLevel: makeAudioLevelHandler(),
      onLowDiskSpace: makeLowDiskSpaceHandler(),
      onContinuityEvent: makeContinuityHandler()
    )

    autoRecorder = recorder
    Log.info(
      Log.monitor, "monitor", "starting auto-recording (call detected, app=\(appName))")

    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await recorder.start()
        self.dependencies.saveAudioRecordingGranted()
        self.permissionNeeded = false
        self.isRecording = true
        self.currentAppName = appName
        self.recordingStartTime = self.dependencies.now()
        self.startElapsedTimer()
        self.notifyRecordingStarted(appName: appName)
      } catch {
        self.setError("Failed to start recording: \(error.localizedDescription)")
        if let recError = error as? RecorderError,
          case .permissionDenied = recError
        {
          self.permissionNeeded = true
        }
        self.autoRecorder = nil
        self.updateAutoState()
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
        lastSavedRecordingURL = url
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
        startAutoRecording(resetRestartBudget: false)
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

  private func cancelGracePeriod() {
    graceTask?.cancel()
    graceTask = nil
    graceCountdown = nil
    consecutiveInactivePolls = 0
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
    let settings = dependencies.loadSettings()
    if autoRecord != settings.autoRecord { autoRecord = settings.autoRecord }
    if gracePeriod != settings.gracePeriod { gracePeriod = settings.gracePeriod }
    if micEnabled != settings.micEnabled { micEnabled = settings.micEnabled }
    if saveDirectory != settings.saveDirectory { saveDirectory = settings.saveDirectory }
    if notifyOnStart != settings.notifyOnStart { notifyOnStart = settings.notifyOnStart }
    if notifyOnSaved != settings.notifyOnSaved { notifyOnSaved = settings.notifyOnSaved }
    if notifyOnError != settings.notifyOnError { notifyOnError = settings.notifyOnError }

    let nextMicPermissionNeeded =
      micEnabled && dependencies.microphoneAuthorizationStatus() != .authorized
    if micPermissionNeeded != nextMicPermissionNeeded {
      micPermissionNeeded = nextMicPermissionNeeded
    }
  }

  private func makeFailureHandler(isManual: Bool) -> @Sendable (RecorderFailure) -> Void {
    { [weak self] failure in
      Task { @MainActor [weak self] in
        guard let self else { return }
        if isManual {
          self.handleManualRecorderFailure(failure)
        } else {
          self.handleAutoRecorderFailure(failure)
        }
      }
    }
  }

  private func makeAudioLevelHandler() -> @Sendable (Float) -> Void {
    { [weak self] level in
      Task { @MainActor [weak self] in
        self?.audioLevel = level
      }
    }
  }

  private func makeLowDiskSpaceHandler() -> @Sendable (Int64) -> Void {
    { [weak self] remaining in
      Task { @MainActor [weak self] in
        self?.handleLowDiskSpace(remaining)
      }
    }
  }

  private func makeContinuityHandler() -> @Sendable (RecorderContinuityEvent) -> Void {
    { [weak self] event in
      Task { @MainActor [weak self] in
        self?.handleRecorderContinuityEvent(event)
      }
    }
  }

  func testSnapshot() -> BlackboxTestSnapshot {
    BlackboxTestSnapshot(
      isRecording: isRecording,
      isManualRecording: isManualRecording,
      isSaving: isSaving,
      currentAppName: currentAppName,
      errorMessage: errorMessage,
      permissionNeeded: permissionNeeded,
      micPermissionNeeded: micPermissionNeeded,
      lastSavedRecordingPath: lastSavedRecordingURL?.path
    )
  }

  // MARK: - Restart Rate Limiting

  private func shouldAllowRestart(
    count: inout Int, windowStart: inout Date?, max: Int = 3, window: TimeInterval = 30
  ) -> Bool {
    let now = dependencies.now()
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
    dependencies.hud.showRecordingStarted(appName: appName)
  }

  private func notifyRecordingSaved(appName: String) {
    guard notifyOnSaved else { return }
    dependencies.hud.showRecordingSaved(appName: appName)
  }

  private func notifyError(message: String) {
    guard notifyOnError else { return }
    dependencies.hud.showError(message: message)
  }

  /// Send system notification when audio recording permission is revoked.
  /// Used because the user may be focused on their call app and not see the menu bar.
  private func notifyPermissionLost() {
    Task { @MainActor [weak self] in
      guard let self else { return }
      await self.dependencies.notifyPermissionLost()
    }
  }
}

extension Double {
  func clamped(to range: ClosedRange<Double>, default defaultValue: Double) -> Double {
    self == 0 ? defaultValue : min(max(self, range.lowerBound), range.upperBound)
  }
}
