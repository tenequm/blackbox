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
  // Track in-flight start() invocations so stopMonitoring can wait for the
  // catch/cleanup path to unwind even if the recorder.start() awaitable
  // returns slowly.
  private var autoStartTask: Task<Void, Never>?
  private var manualStartTask: Task<Void, Never>?
  // After a user-initiated stop (manual stop, or force-stop on auto), suppress
  // auto-restart of the same parent bundle until it disappears from the caller
  // set for one poll. Single-bundle: covers the reported Chrome case;
  // multi-caller suppression is speculative and out of scope.
  private var suppressedBundleID: String?

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
  var namePrefixTemplate: String = ""
  var notifyOnStart: Bool = true
  var notifyOnSaved: Bool = true
  var notifyOnError: Bool = true
  var excludedBundleIDs: Set<String> = []

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

    // Screen Recording permission is requested at onboarding; if it was revoked
    // or never granted, recording fails with .permissionDenied and the failure
    // handler sets permissionNeeded = true.

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

    // Snapshot start tasks before we await anything. The Task body clears
    // its own field via defer; awaiting the snapshot makes the wait
    // deterministic regardless of completion order.
    let autoTask = autoStartTask
    let manualTask = manualStartTask

    if let recorder = autoRecorder {
      reportRecordingSaved(await recorder.stop())
      autoRecorder = nil
    }

    if let recorder = manualRecorder {
      reportRecordingSaved(await recorder.stop())
      manualRecorder = nil
      isManualRecording = false
    }

    // Wait for any in-flight start() Task to unwind (success or catch path)
    // so applicationShouldTerminate's 8s budget is honored.
    await autoTask?.value
    await manualTask?.value

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
        isManualRecording: true,
        titlePrefix: formatNamePrefix(template: namePrefixTemplate, date: dependencies.now())
      ),
      onFailure: makeFailureHandler(isManual: true),
      onAudioLevel: makeAudioLevelHandler(),
      onLowDiskSpace: makeLowDiskSpaceHandler(),
      onContinuity: makeContinuityHandler()
    )

    manualRecorder = recorder
    isManualRecording = true

    self.manualStartTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.manualStartTask = nil }
      do {
        try await recorder.start()
        // Identity guard: if stop arrived during start(), the recorder we
        // hold is no longer the one we kicked off. Don't promote state.
        guard self.manualRecorder === recorder else { return }
        self.permissionNeeded = false
        self.recordingStartTime = self.dependencies.now()
        self.currentAppName = "Manual recording"
        self.isRecording = true
        self.startElapsedTimer()
        self.notifyRecordingStarted(appName: "Manual recording")
      } catch {
        // Suppress error toast for cancellations (stop during start) and
        // lost-race situations (stop nilled the recorder before start
        // returned). Use pattern matching to avoid requiring Equatable on
        // RecorderError.
        var isCancel = false
        if let recError = error as? RecorderError, case .cancelled = recError {
          isCancel = true
        }
        let lostRace = self.manualRecorder !== recorder
        if !(isCancel || lostRace) {
          self.setError("Failed to start recording: \(error.localizedDescription)")
        }
        if !lostRace {
          self.manualRecorder = nil
          self.isManualRecording = false
        }
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
      reportRecordingSaved(await failedRecorder.stop())
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
    case .displayLost:
      // Display sleep, not a fault: restart unconditionally. start() waits for
      // a display to come back, so this does not spin against the budget.
      Log.info(Log.monitor, "monitor", "display lost during manual recording, restarting")
      setError("Display slept - resuming recording...")
      startManualRecording(resetRestartBudget: false)
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

  /// Announces a recording that reached disk. Every `stop()` that can return a
  /// URL funnels through here so post-processing sees failure-ended and
  /// quit-time recordings too, not just the two clean stop paths.
  private func reportRecordingSaved(_ url: URL?) {
    guard let url else { return }
    dependencies.onRecordingSaved(url)
  }

  func forceStopAutoRecording() {
    cancelGracePeriod()
    stopAutoRecording(suppressBundleAfterStop: true)
  }

  func stopManualRecording() {
    guard let recorder = manualRecorder else { return }
    // Snapshot before any state change so we suppress the bundle the user
    // was just recording. Manual recordings have no `autoRecordingBundleID`,
    // so the first currently-active resolved caller is the closest signal.
    suppressedBundleID = firstActiveResolvedCaller()
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
        reportRecordingSaved(url)
      }
      updateAutoState()
      // Force re-evaluation so auto-recording starts if a call is still active
      lastKnownMicRunning = false
      evaluateCallState()
    }
  }

  // MARK: - Call Detection (macOS 14.2+)

  private func setupCallDetection() {
    let callers = resolvedActiveCallers()
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
    let resolvedCallers = resolvedActiveCallers()

    // Clear suppression once the suppressed bundle disappears from the full
    // caller set. We check against `resolvedCallers` (not `eligibleCallers`)
    // so the bundle leaving its own suppression set actually clears it.
    if let suppressed = suppressedBundleID, !resolvedCallers.contains(suppressed) {
      suppressedBundleID = nil
    }

    // Eligible callers exclude the suppressed bundle, so other apps (e.g.
    // Zoom) can still trigger auto-record while Chrome is suppressed.
    let eligibleCallers: [String]
    if let suppressed = suppressedBundleID {
      eligibleCallers = resolvedCallers.filter { $0 != suppressed }
    } else {
      eligibleCallers = resolvedCallers
    }
    let running = !eligibleCallers.isEmpty

    if running {
      consecutiveInactivePolls = 0
      continuityCooldownUntil = nil
      if running != lastKnownMicRunning {
        Log.info(
          Log.monitor, "monitor",
          "call state changed: eligibleCallers=\(eligibleCallers.count), running=\(running)")
        lastKnownMicRunning = true
        let bundleID = eligibleCallers.count == 1 ? eligibleCallers.first : nil
        handleMicBecameActive(appBundleID: bundleID)
      } else if autoRecord, autoRecorder == nil, !isRecording, !isManualRecording {
        Log.info(Log.monitor, "monitor", "retrying auto-recording for active call")
        handleMicBecameActive(appBundleID: eligibleCallers.first)
      }
      return
    }

    if running != lastKnownMicRunning {
      Log.info(
        Log.monitor, "monitor",
        "call state changed: eligibleCallers=\(eligibleCallers.count), running=\(running)")
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

  /// Active callers resolved to parent bundle IDs, with excluded apps removed.
  /// Single source for "who is calling" - exclusion must also apply to
  /// suppression seeding, so an excluded bundle never occupies the slot.
  private func resolvedActiveCallers() -> [String] {
    dependencies.findActiveCallingProcesses()
      .compactMap { $0 }
      .map(Self.resolveParentBundleID)
      .filter { !excludedBundleIDs.contains($0) }
  }

  /// First currently-active caller resolved to its parent bundle ID. Used by
  /// stop paths that need to seed `suppressedBundleID` when no
  /// `autoRecordingBundleID` is available (e.g. manual stop or multi-caller
  /// auto stop).
  private func firstActiveResolvedCaller() -> String? {
    resolvedActiveCallers().first
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

    // Screen Recording permission is checked when AudioRecorder.start() creates
    // the SCStream. If denied, the failure callback sets permissionNeeded = true.

    autoRecordingBundleID = appBundleID.map { Self.resolveParentBundleID($0) }
    autoRecordingAppName = Self.resolveAppName(bundleID: appBundleID)
    loadSettings()
    // Re-check against the freshly loaded set: the poll that got us here may
    // have filtered with exclusions up to 5s stale.
    if let bundleID = autoRecordingBundleID, excludedBundleIDs.contains(bundleID) {
      Log.info(Log.monitor, "monitor", "auto-recording skipped: \(bundleID) is excluded")
      return
    }
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

  private func handleRecorderContinuity() {
    let now = dependencies.now()
    continuityCooldownUntil = now.addingTimeInterval(max(gracePeriod, 8))
    consecutiveInactivePolls = 0
    cancelGracePeriod()
    Log.info(Log.monitor, "monitor", "continuity event observed")
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
        isManualRecording: false,
        titlePrefix: formatNamePrefix(template: namePrefixTemplate, date: dependencies.now())
      ),
      onFailure: makeFailureHandler(isManual: false),
      onAudioLevel: makeAudioLevelHandler(),
      onLowDiskSpace: makeLowDiskSpaceHandler(),
      onContinuity: makeContinuityHandler()
    )

    autoRecorder = recorder
    Log.info(
      Log.monitor, "monitor", "starting auto-recording (call detected, app=\(appName))")

    self.autoStartTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.autoStartTask = nil }
      do {
        try await recorder.start()
        // Identity guard: if stop arrived during start(), the recorder we
        // hold is no longer the one we kicked off. Don't promote state.
        guard self.autoRecorder === recorder else { return }
        self.permissionNeeded = false
        self.isRecording = true
        self.currentAppName = appName
        self.recordingStartTime = self.dependencies.now()
        self.startElapsedTimer()
        self.notifyRecordingStarted(appName: appName)
      } catch {
        // Pattern-match instead of relying on Equatable on RecorderError so
        // future associated values do not silently break this branch.
        var isCancel = false
        if let recError = error as? RecorderError, case .cancelled = recError {
          isCancel = true
        }
        let lostRace = self.autoRecorder !== recorder
        if !(isCancel || lostRace) {
          self.setError("Failed to start recording: \(error.localizedDescription)")
          if let recError = error as? RecorderError,
            case .permissionDenied = recError
          {
            self.permissionNeeded = true
          }
        }
        if !lostRace {
          self.autoRecorder = nil
        }
        self.updateAutoState()
      }
    }
  }

  private func stopAutoRecording(suppressBundleAfterStop: Bool = false) {
    guard let recorder = autoRecorder else { return }
    // Suppress only on user-initiated stops (forceStopAutoRecording). Grace
    // expiry leaves suppression alone so a re-detected call can record again
    // without waiting for the bundle to flap absent->present.
    if suppressBundleAfterStop {
      suppressedBundleID = autoRecordingBundleID ?? firstActiveResolvedCaller()
    }
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
        reportRecordingSaved(url)
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
      reportRecordingSaved(await failedRecorder.stop())
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
    case .displayLost:
      Log.info(Log.monitor, "monitor", "display lost during auto-recording, restarting")
      startAutoRecording(resetRestartBudget: false)
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
    if namePrefixTemplate != settings.namePrefixTemplate {
      namePrefixTemplate = settings.namePrefixTemplate
    }
    if notifyOnStart != settings.notifyOnStart { notifyOnStart = settings.notifyOnStart }
    if notifyOnSaved != settings.notifyOnSaved { notifyOnSaved = settings.notifyOnSaved }
    if notifyOnError != settings.notifyOnError { notifyOnError = settings.notifyOnError }
    if excludedBundleIDs != settings.excludedBundleIDs {
      excludedBundleIDs = settings.excludedBundleIDs
    }

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

  private func makeContinuityHandler() -> @Sendable () -> Void {
    { [weak self] in
      Task { @MainActor [weak self] in
        self?.handleRecorderContinuity()
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
