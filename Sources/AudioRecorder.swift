@preconcurrency import AVFoundation
@preconcurrency import AudioToolbox
import CoreAudio
import ObjCExceptionCatcher
@preconcurrency import ScreenCaptureKit

/// Records system audio via ScreenCaptureKit (SCStream, display-wide) and mic via
/// AVAudioEngine as independent pipelines.
///
/// Dual-track capture: system audio (SCStream) and mic (AVAudioEngine) written as
/// separate AVAssetWriterInputs to a single M4A file. No post-processing or mixing.
/// Uses a custom DispatchSerialQueue executor - all actor-isolated state is
/// accessed on `audioQueue`.
///
/// AVAudioEngine handles mic device following automatically - on hardware change,
/// the `AVAudioEngineConfigurationChange` notification fires and the tap is
/// reinstalled. `movieFragmentInterval` ensures partial file recovery on crash.
actor AudioRecorder {
  nonisolated let bundleID: String?
  nonisolated let appName: String
  nonisolated let titlePrefix: String
  nonisolated let micEnabled: Bool
  nonisolated let saveDirectory: URL
  nonisolated let isManualRecording: Bool

  nonisolated let onFailure: (@Sendable (RecorderFailure) -> Void)?
  nonisolated let onAudioLevel: (@Sendable (Float) -> Void)?
  nonisolated let onLowDiskSpace: (@Sendable (Int64) -> Void)?
  nonisolated let onContinuity: (@Sendable () -> Void)?

  private nonisolated let audioQueue = DispatchSerialQueue(
    label: "com.tenequm.blackbox.audio")
  nonisolated var unownedExecutor: UnownedSerialExecutor {
    audioQueue.asUnownedSerialExecutor()
  }

  // SCStream state
  private var displayStream: SCStream?
  private var streamProxy: SCStreamProxy?

  // AVAudioEngine
  private var audioEngine: AVAudioEngine?
  private var configChangeObserver: (any NSObjectProtocol)?

  // D12: supplemental mic-recovery signals.
  // `defaultInputListenerBlock` is stored because AudioObjectRemovePropertyListenerBlock
  // requires the same block reference that was passed to Add. Typed as an
  // explicit `@Sendable` closure (rather than the non-Sendable
  // `AudioObjectPropertyListenerBlock` typealias) so `deinit` can read it.
  // `micWatchdogTimer` ticks on audioQueue and trips when buffers stop flowing.
  private var defaultInputListenerBlock:
    (@Sendable (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void)?
  private var micWatchdogTimer: DispatchSourceTimer?
  private static let micStallThresholdSeconds: Double = 2.0
  private static let micWatchdogTickSeconds: Double = 1.0

  // Writer state
  private var pipeline: RecordingPipeline?
  // Lifecycle phase. `cancelRequested` is set synchronously by `stop()` so an
  // in-flight `start()` resuming from any await observes the cancel and bails
  // through `checkAlive()` regardless of which phase stop() ran in.
  private enum Phase { case notStarted, starting, running, stopped }
  private var phase: Phase = .notStarted
  private var cancelRequested = false
  private var activity: NSObjectProtocol?
  private var diskSpaceTimer: DispatchSourceTimer?
  private var lowDiskSpaceWarned = false
  private var micBuffersConversionFailed: Int = 0
  private var configChangeGeneration: Int = 0

  // D9: device latency offset for mic-system alignment.
  // `micLatencyOffsetTicks` is the mach host-time equivalent of `micLatencyOffset`,
  // cached so we do not call `AudioConvertNanosToHostTime` on every mic buffer.
  private var micLatencyOffset: Double = 0
  private var micLatencyOffsetTicks: UInt64 = 0

  // Drift monitor state. Raw host times from the most recent buffer delivered
  // by each path, plus a 5s log timer. Used to surface mic-vs-system clock
  // skew or drift during a live recording.
  private var driftTimer: DispatchSourceTimer?
  private var lastMicHostTime: UInt64 = 0

  // Per-channel RMS diagnostic for voice-processing layouts (>2ch, e.g.
  // FaceTime active): logged once per episode to identify the mic channel.
  private var micDiagSumSq: [Double] = []
  private var micDiagFrames = 0
  private var micDiagLogged = false
  private var lastSystemHostTime: UInt64 = 0
  private var driftStartHost: UInt64 = 0

  enum StartCheckpoint: Sendable {
    case beforeContent
    case afterPipeline
    case afterStreamStart
  }

  nonisolated let testStartCheckpoint: (@Sendable (StartCheckpoint) async -> Void)?

  init(
    bundleID: String? = nil, appName: String, micEnabled: Bool,
    saveDirectory: URL,
    isManualRecording: Bool = false,
    titlePrefix: String = "",
    onFailure: (@Sendable (RecorderFailure) -> Void)? = nil,
    onAudioLevel: (@Sendable (Float) -> Void)? = nil,
    onLowDiskSpace: (@Sendable (Int64) -> Void)? = nil,
    onContinuity: (@Sendable () -> Void)? = nil,
    testStartCheckpoint: (@Sendable (StartCheckpoint) async -> Void)? = nil
  ) {
    self.bundleID = bundleID
    self.appName = appName
    self.micEnabled = micEnabled
    self.saveDirectory = saveDirectory
    self.isManualRecording = isManualRecording
    self.titlePrefix = titlePrefix
    self.onFailure = onFailure
    self.onAudioLevel = onAudioLevel
    self.onLowDiskSpace = onLowDiskSpace
    self.onContinuity = onContinuity
    self.testStartCheckpoint = testStartCheckpoint
  }

  deinit {
    if let configChangeObserver {
      NotificationCenter.default.removeObserver(configChangeObserver)
    }
    // D12 defensive cleanup in case the caller skipped stop().
    // DispatchSourceTimer traps if released while still resumed;
    // AudioObjectRemovePropertyListenerBlock requires the original block
    // reference, which is lost once this deinit returns.
    micWatchdogTimer?.cancel()
    if let block = defaultInputListenerBlock {
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain))
      AudioObjectRemovePropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject), &address, audioQueue, block)
    }
    if let activity { ProcessInfo.processInfo.endActivity(activity) }
  }

  // MARK: - Start / Stop

  /// Throws `.cancelled` if `stop()` arrived during `start()`. Called after
  /// every await so a reentrant stop terminates the in-flight start before
  /// it can register more resources.
  private func checkAlive() throws {
    if cancelRequested { throw RecorderError.cancelled }
  }

  /// Starts capturing audio and writing to file immediately.
  ///
  /// Lifecycle: phase transitions notStarted -> starting -> running. If
  /// `stop()` arrives during a startup await, `cancelRequested` flips and
  /// the next `checkAlive()` throws `RecorderError.cancelled`; the catch
  /// path tears down any partial state via `cleanupPartialStart()`.
  func start() async throws {
    precondition(phase == .notStarted, "AudioRecorder.start() called more than once")
    phase = .starting
    Log.info(Log.recorder, "recorder", "start() for \(appName) (\(bundleID ?? "all"))")

    do {
      await testStartCheckpoint?(.beforeContent)
      try checkAlive()

      // 1. Discover a display to drive the system-audio SCStream.
      let content = try await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: false)
      try checkAlive()
      guard let display = content.displays.first else {
        Log.error(Log.recorder, "recorder", "no display found for \(appName)")
        throw RecorderError.noDisplay
      }

      // Display-wide audio capture (no window/app exclusions). SCStream's display
      // mix is driven by the OS-composited output path, not a specific hardware
      // clock, so it is resilient to idle/pinned/stalled output devices.
      let filter = SCContentFilter(
        display: display, excludingApplications: [], exceptingWindows: [])
      let config = makeStreamConfig()

      let pipeline = RecordingPipeline(
        bundleID: bundleID,
        appName: appName,
        micEnabled: micEnabled,
        saveDirectory: saveDirectory,
        titlePrefix: titlePrefix,
        alignmentMode: isManualRecording ? .preserveAllContent : .waitForAllTracks,
        onFailure: onFailure,
        onAudioLevel: onAudioLevel,
        armSessionStartTimeout: { [weak self] in
          guard let self else { return }
          // Poke `tryStartSessionFromTimeout` ~500ms after the first sample
          // arrives so the wall-clock fallback still fires even if the second
          // track stops delivering buffers entirely. Hop through `audioQueue`
          // so the pipeline's single-threaded access invariant is preserved.
          let delay: DispatchTimeInterval = .milliseconds(
            Int(RecordingPipeline.sessionStartTimeoutSeconds * 1000) + 10)
          self.audioQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.assumeIsolated { iso in
              iso.pipeline?.tryStartSessionFromTimeout()
            }
          }
        }
      )
      // Assign before pipeline.start() so a partial-init throw is reachable
      // from cleanupPartialStart's take-and-nil sweep.
      self.pipeline = pipeline
      try pipeline.start()

      await testStartCheckpoint?(.afterPipeline)
      try checkAlive()

      let proxy = SCStreamProxy(audioQueue: audioQueue)
      proxy.recorder = self
      self.streamProxy = proxy

      let stream = SCStream(filter: filter, configuration: config, delegate: proxy)
      try stream.addStreamOutput(proxy, type: .audio, sampleHandlerQueue: audioQueue)
      self.displayStream = stream

      activity = ProcessInfo.processInfo.beginActivity(
        options: .userInitiated,
        reason: "Recording call audio"
      )

      try await stream.startCapture()
      // Flip to .running synchronously after startCapture returns so the
      // `phase == .running` guard on handleSystemSampleBuffer accepts buffers
      // from first delivery. No await between here and the flip.
      phase = .running
      Log.info(Log.recorder, "recorder", "SCStream started for \(appName)")

      await testStartCheckpoint?(.afterStreamStart)
      try checkAlive()

      startDiskSpaceMonitor()
      if micEnabled { startDriftMonitor() }

      // Start mic capture independently - failure does not stop system audio.
      if micEnabled {
        do {
          try startMicCapture()
        } catch {
          Log.error(
            Log.recorder, "recorder",
            "mic capture failed to start, continuing without mic: \(error)")
        }
      }
    } catch {
      Log.error(Log.recorder, "recorder", "recording setup failed for \(appName): \(error)")
      await cleanupPartialStart()
      phase = .stopped
      throw mappedStartError(error)
    }
  }

  /// Reentrancy-safe partial-start teardown. Snapshots resources to local
  /// lets, nils the actor fields synchronously, then awaits teardown on the
  /// snapshots. A second concurrent caller (e.g. stop() racing against the
  /// catch block) sees nil fields and is a no-op. Mic teardown delegates to
  /// `stopMicCapture()` because nilling `defaultInputListenerBlock` and
  /// `configChangeObserver` directly would leak the registered listeners.
  private func cleanupPartialStart() async {
    stopMicCapture()

    let stream = displayStream
    let pipe = pipeline
    let activitySnap = activity
    let dskTimer = diskSpaceTimer
    let drftTimer = driftTimer

    displayStream = nil
    streamProxy = nil
    pipeline = nil
    activity = nil
    diskSpaceTimer = nil
    driftTimer = nil

    if let stream {
      // Race stopCapture against a 3s timeout (mirrors the steady-state stop
      // path) so a hung SCStream cannot exceed applicationShouldTerminate's
      // 8s budget.
      await withTaskGroup(of: Void.self) { group in
        group.addTask { try? await stream.stopCapture() }
        group.addTask { try? await Task.sleep(for: .seconds(3)) }
        await group.next()
        group.cancelAll()
      }
    }
    if let pipe { _ = await pipe.stop() }
    if let activitySnap { ProcessInfo.processInfo.endActivity(activitySnap) }
    dskTimer?.cancel()
    drftTimer?.cancel()
  }

  /// Stops capture and finalizes the recording file.
  @discardableResult
  func stop() async -> URL? {
    Log.info(Log.recorder, "recorder", "stop() for \(appName) (phase=\(phase))")

    switch phase {
    case .notStarted:
      cancelRequested = true
      phase = .stopped
      return nil

    case .starting:
      // Synchronous flip so an in-flight start() resuming from any await
      // observes the cancel via checkAlive() and bails into its catch path.
      cancelRequested = true
      await cleanupPartialStart()
      phase = .stopped
      return nil

    case .running:
      // Defensive: future test seams could suspend start() past .running.
      // Setting cancelRequested ensures any such suspended start aborts.
      cancelRequested = true
      return await stopRunning()

    case .stopped:
      return nil
    }
  }

  /// Steady-state teardown: stream stop with timeout, mic teardown, finalize
  /// writer, return saved URL.
  private func stopRunning() async -> URL? {
    if let stream = displayStream {
      // Race stopCapture against a 3s timeout so a hung SCStream (documented
      // under WindowServer stalls) cannot exceed applicationShouldTerminate's
      // 8s budget and corrupt the recording.
      await withTaskGroup(of: Void.self) { group in
        group.addTask { try? await stream.stopCapture() }
        group.addTask { try? await Task.sleep(for: .seconds(3)) }
        await group.next()
        group.cancelAll()
      }
    }
    self.displayStream = nil
    self.streamProxy = nil

    phase = .stopped

    // Delegates to stopMicCapture so the D12 watchdog + default-input listener
    // + configChangeObserver + engine teardown all run in one place. With
    // `phase = .stopped` already set above, any in-flight mic tap callback
    // arriving during the teardown short-circuits inside handleMicBuffer.
    stopMicCapture()

    let diagnostics = pipeline?.currentDiagnostics
    let systemStats = diagnostics?.system ?? TrackDiagnostics()
    Log.info(
      Log.recorder, "recorder",
      "system stats: received=\(systemStats.buffersReceived) appended=\(systemStats.buffersAppended) notReady=\(systemStats.buffersDroppedNotReady) appendFail=\(systemStats.buffersAppendFailed)"
    )
    if micEnabled {
      let micStats = diagnostics?.mic ?? TrackDiagnostics()
      Log.info(
        Log.recorder, "recorder",
        "mic stats: received=\(micStats.buffersReceived) appended=\(micStats.buffersAppended) notReady=\(micStats.buffersDroppedNotReady) convFail=\(micBuffersConversionFailed) appendFail=\(micStats.buffersAppendFailed) gapsFilled=\(micStats.gapsFilled) tailPad=\(String(format: "%.3f", micStats.tailPaddingSeconds))s"
      )
    }
    diskSpaceTimer?.cancel()
    diskSpaceTimer = nil
    driftTimer?.cancel()
    driftTimer = nil
    lastMicHostTime = 0
    lastSystemHostTime = 0
    driftStartHost = 0
    lowDiskSpaceWarned = false
    micLatencyOffset = 0
    micLatencyOffsetTicks = 0
    let pipeline = self.pipeline
    self.pipeline = nil
    let savedURL = await pipeline?.stop()

    if let activity {
      ProcessInfo.processInfo.endActivity(activity)
      self.activity = nil
    }

    return savedURL
  }

  // MARK: - SCStream Configuration

  /// Builds the audio-only SCStreamConfiguration. The tiny 2x2 frame and
  /// infinite `minimumFrameInterval` suppress video pipeline overhead; only
  /// the `.audio` output is subscribed.
  private func makeStreamConfig() -> SCStreamConfiguration {
    let config = SCStreamConfiguration()
    config.width = 2
    config.height = 2
    config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale.max)
    config.showsCursor = false
    config.capturesAudio = true
    config.sampleRate = Int(RecordingPipeline.writerSampleRate)
    config.channelCount = 2
    config.excludesCurrentProcessAudio = true
    config.captureMicrophone = false
    return config
  }

  // MARK: - SCStream Callbacks (called from SCStreamProxy via assumeIsolated)

  /// Handles a system-audio CMSampleBuffer delivered by SCStream on `audioQueue`.
  ///
  /// Matches v0.6.0 semantics: SCStream delivers the CMSampleBuffer in its
  /// native 48 kHz stereo Float32 format and we append it directly to a stereo
  /// 128 kbps AAC writer input. No PCM round-trip, no downmix, no re-wrap.
  fileprivate func handleSystemSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
    guard phase == .running else { return }
    guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }

    // Host ticks of callback arrival - symmetric with the mic path, which
    // records `AVAudioTime.hostTime` from its tap callback. Avoids assuming
    // SCStream's PTS sits on the host-time clock.
    lastSystemHostTime = mach_absolute_time()

    pipeline?.appendSystemSample(sampleBuffer)
  }

  /// SCStream delegate reported that the stream stopped. Map the error to
  /// the recovery vocabulary `AudioMonitor` understands.
  fileprivate func handleStreamStopped(code: Int, description: String) {
    guard phase != .stopped else { return }
    let failure: RecorderFailure
    switch code {
    case -3801: failure = .permissionDenied
    case -3802, -3821: failure = .systemStopped
    default: failure = .other(description)
    }
    Log.error(
      Log.recorder, "recorder",
      "SCStream stopped for \(appName) (code=\(code)): \(description)")
    onFailure?(failure)
  }

  /// Wraps start-time ScreenCaptureKit errors in `RecorderFailure`-friendly
  /// `RecorderError` cases so the caller sees a stable failure surface.
  /// Mirrors the code routing in `handleStreamStopped`.
  private func mappedStartError(_ error: any Error) -> any Error {
    let nsError = error as NSError
    guard nsError.domain == SCStreamErrorDomain else { return error }
    switch nsError.code {
    case -3801: return RecorderError.permissionDenied
    case -3802, -3821: return RecorderError.systemStopped
    default: return error
    }
  }

  // MARK: - AVAudioEngine Mic Capture

  private func startMicCapture() throws {
    // Log mic permission status for diagnostics
    let micAuth = AVCaptureDevice.authorizationStatus(for: .audio)
    let authName: String
    switch micAuth {
    case .authorized: authName = "authorized"
    case .denied: authName = "DENIED"
    case .restricted: authName = "RESTRICTED"
    case .notDetermined: authName = "notDetermined"
    @unknown default: authName = "unknown(\(micAuth.rawValue))"
    }

    let engine = AVAudioEngine()

    // inputNode access throws NSException if no input device exists
    var inputNodeException: NSException?
    guard let inputNode = ObjCGetInputNode(engine, &inputNodeException) else {
      let reason = inputNodeException?.reason ?? inputNodeException?.name.rawValue ?? "unknown"
      throw NSError(
        domain: "Blackbox", code: -1,
        userInfo: [NSLocalizedDescriptionKey: "No audio input device: \(reason)"])
    }

    // Log the actual input device being used
    let inputDeviceID = inputNode.auAudioUnit.deviceID
    let deviceName = Self.audioDeviceName(for: inputDeviceID) ?? "unknown"

    let nativeFormat = inputNode.inputFormat(forBus: 0)
    guard nativeFormat.sampleRate > 0, nativeFormat.channelCount > 0 else {
      throw NSError(
        domain: "Blackbox", code: -1,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Invalid mic format: \(nativeFormat.sampleRate)Hz, \(nativeFormat.channelCount)ch"
        ])
    }
    Log.info(
      Log.recorder, "recorder",
      "mic format: \(nativeFormat.channelCount)ch, \(nativeFormat.sampleRate)Hz, device: \(deviceName) (\(inputDeviceID)), permission: \(authName)"
    )
    let tapHandler = makeMicTapHandler()

    // installTap throws NSException on format mismatch or invalid state
    if let e = ObjCInstallTap(inputNode, 0, 1024, nativeFormat, tapHandler) {
      throw NSError(
        domain: "Blackbox", code: -1,
        userInfo: [NSLocalizedDescriptionKey: "installTap failed: \(e.reason ?? e.name.rawValue)"])
    }

    // engine.start() can throw NSExceptions and NSErrors - catch both
    var startError: NSError?
    if let e = ObjCStartEngine(engine, &startError) {
      let _ = ObjCRemoveTap(inputNode, 0)
      throw NSError(
        domain: "Blackbox", code: -1,
        userInfo: [NSLocalizedDescriptionKey: "engine.start failed: \(e.reason ?? e.name.rawValue)"]
      )
    }
    if let startError {
      let _ = ObjCRemoveTap(inputNode, 0)
      throw startError
    }
    audioEngine = engine

    // D12: prime the watchdog baseline. Without this, a dead-on-arrival
    // engine (engine.start() succeeded but no buffers ever flow) would not
    // be detected, because `lastMicHostTime` would stay zero.
    lastMicHostTime = mach_absolute_time()

    // D9: query initial mic latency offset
    queryMicLatencyOffset(deviceID: inputDeviceID)

    configChangeObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange,
      object: engine,
      queue: nil
    ) { [weak self] _ in
      guard let self else { return }
      Task { await self.requestMicReinstall(source: "avaudioengine_notification") }
    }

    // D12: supplemental recovery signals.
    installDefaultInputListener()
    startMicWatchdog()

    Log.info(
      Log.recorder, "recorder",
      "mic capture started via AVAudioEngine (format: \(nativeFormat), resample: \(nativeFormat.sampleRate != 48000))"
    )
  }

  private func stopMicCapture() {
    configChangeGeneration += 1
    stopMicWatchdog()
    removeDefaultInputListener()
    if let observer = configChangeObserver {
      NotificationCenter.default.removeObserver(observer)
      configChangeObserver = nil
    }
    if let engine = audioEngine {
      var exc: NSException?
      if let inputNode = ObjCGetInputNode(engine, &exc) {
        let _ = ObjCRemoveTap(inputNode, 0)
      }
      let _ = ObjCStopEngine(engine)
      audioEngine = nil
    }
  }

  /// Creates a mic tap handler that dispatches to audioQueue.
  nonisolated private func makeMicTapHandler()
    -> @Sendable (AVAudioPCMBuffer, AVAudioTime) ->
    Void
  {
    return { [weak self] buffer, when in
      guard let self else { return }
      self.audioQueue.async { [weak self] in
        guard let self else { return }
        self.assumeIsolated { iso in
          iso.handleMicBuffer(buffer, at: when)
        }
      }
    }
  }

  /// Handles mic audio buffer on audioQueue.
  private func handleMicBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
    guard phase == .running else { return }
    if time.isHostTimeValid {
      lastMicHostTime = time.hostTime
    }

    if buffer.format.channelCount > 2 {
      if !micDiagLogged { accumulateMicChannelDiag(buffer) }
    } else if micDiagLogged || micDiagFrames > 0 {
      micDiagSumSq = []
      micDiagFrames = 0
      micDiagLogged = false
    }

    // D9: apply cached latency offset (in host ticks) to the mic PTS.
    let adjustedTime: AVAudioTime
    if micLatencyOffsetTicks > 0, time.isHostTimeValid {
      let adjustedHostTime =
        time.hostTime > micLatencyOffsetTicks
        ? time.hostTime - micLatencyOffsetTicks : time.hostTime
      adjustedTime = AVAudioTime(hostTime: adjustedHostTime)
    } else {
      adjustedTime = time
    }

    // Resample to 48kHz if device rate differs (e.g. 24kHz AirPods).
    // Linear interpolation - adequate for voice audio, avoids AVAudioConverter @Sendable issues.
    let outputBuffer: AVAudioPCMBuffer
    if buffer.format.sampleRate != RecordingPipeline.writerSampleRate
      || buffer.format.channelCount != 1
    {
      guard
        let resampled = RecordingPipeline.resampleToMono48k(
          buffer, sourceRate: buffer.format.sampleRate)
      else {
        micBuffersConversionFailed += 1
        return
      }
      outputBuffer = resampled
    } else {
      outputBuffer = buffer
    }

    guard let sampleBuffer = outputBuffer.asSampleBuffer(timestamp: adjustedTime) else {
      micBuffersConversionFailed += 1
      Log.warning(Log.recorder, "recorder", "mic PCM-to-CMSampleBuffer conversion failed")
      return
    }
    pipeline?.appendMicSample(sampleBuffer)
  }

  /// Accumulates ~2s of per-channel energy from multichannel mic buffers,
  /// then logs RMS dBFS per channel so a live call can confirm which channel
  /// carries the mic in voice-processing layouts.
  private func accumulateMicChannelDiag(_ buffer: AVAudioPCMBuffer) {
    guard let data = buffer.floatChannelData else { return }
    let channels = Int(buffer.format.channelCount)
    let frames = Int(buffer.frameLength)
    guard frames > 0 else { return }
    if micDiagSumSq.count != channels {
      micDiagSumSq = Array(repeating: 0, count: channels)
      micDiagFrames = 0
    }
    if buffer.format.isInterleaved {
      let p = data[0]
      for c in 0..<channels {
        var sum = 0.0
        for f in 0..<frames {
          let v = Double(p[f * channels + c])
          sum += v * v
        }
        micDiagSumSq[c] += sum
      }
    } else {
      for c in 0..<channels {
        let p = data[c]
        var sum = 0.0
        for f in 0..<frames {
          let v = Double(p[f])
          sum += v * v
        }
        micDiagSumSq[c] += sum
      }
    }
    micDiagFrames += frames
    guard micDiagFrames >= 96_000 else { return }
    let dbfs = micDiagSumSq.map { sumSq -> String in
      let rms = (sumSq / Double(micDiagFrames)).squareRoot()
      return rms > 0 ? String(format: "%.1f", 20 * log10(rms)) : "-inf"
    }
    Log.info(
      Log.recorder, "recorder",
      "mic multichannel diagnostic: \(channels)ch, rms dBFS per channel: [\(dbfs.joined(separator: ", "))]"
    )
    micDiagLogged = true
    micDiagSumSq = []
    micDiagFrames = 0
  }

  /// Debounces rapid config change notifications (e.g. Krisp device switching).
  /// Dispatches to audioQueue with 300ms delay; only the last notification fires.
  private func debounceConfigChange(engine: AVAudioEngine) {
    configChangeGeneration += 1
    let gen = configChangeGeneration
    audioQueue.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
      guard let self else { return }
      self.assumeIsolated { iso in
        guard iso.phase != .stopped, iso.configChangeGeneration == gen else { return }
        iso.handleEngineConfigChange(engine: engine)
      }
    }
  }

  /// Handles AVAudioEngine configuration change (device plugged/unplugged).
  /// Runs on audioQueue to serialize with stopped flag and buffer handling.
  /// Reinstalls tap and restarts engine. System audio continues regardless.
  private func handleEngineConfigChange(engine: AVAudioEngine) {
    guard phase != .stopped else { return }
    onContinuity?()
    Log.info(Log.recorder, "recorder", "audio engine config changed, restarting mic capture")

    // D12: give the watchdog a fresh 2s window regardless of whether the
    // reinstall succeeds below. If buffers arrive, they will keep pushing
    // `lastMicHostTime` forward; if they do not, the watchdog will trip
    // again after 2s and retry.
    defer { lastMicHostTime = mach_absolute_time() }

    var inputNodeException: NSException?
    guard let inputNode = ObjCGetInputNode(engine, &inputNodeException) else {
      if let e = inputNodeException {
        Log.error(
          Log.recorder, "recorder",
          "inputNode access failed after device change: \(e.reason ?? e.name.rawValue)")
      }
      return
    }

    let _ = ObjCRemoveTap(inputNode, 0)

    let nativeFormat = inputNode.inputFormat(forBus: 0)
    guard nativeFormat.sampleRate > 0, nativeFormat.channelCount > 0 else {
      Log.error(
        Log.recorder, "recorder",
        "invalid format after device change: \(nativeFormat.sampleRate)Hz, \(nativeFormat.channelCount)ch"
      )
      return
    }
    Log.info(
      Log.recorder, "recorder",
      "device format after change: \(nativeFormat.channelCount)ch, \(nativeFormat.sampleRate)Hz, resample: \(nativeFormat.sampleRate != 48000)"
    )

    let tapHandler = makeMicTapHandler()

    if let e = ObjCInstallTap(inputNode, 0, 1024, nativeFormat, tapHandler) {
      Log.error(
        Log.recorder, "recorder",
        "installTap failed after device change: \(e.reason ?? e.name.rawValue)")
      return
    }

    var startError: NSError?
    if let e = ObjCStartEngine(engine, &startError) {
      Log.error(
        Log.recorder, "recorder",
        "engine.start exception after device change: \(e.reason ?? e.name.rawValue)")
      let _ = ObjCRemoveTap(inputNode, 0)
      return
    }
    if let startError {
      Log.error(
        Log.recorder, "recorder",
        "engine.start failed after device change: \(startError)")
      let _ = ObjCRemoveTap(inputNode, 0)
      return
    }

    // D9: re-query latency for new device
    let inputDeviceID = inputNode.auAudioUnit.deviceID
    queryMicLatencyOffset(deviceID: inputDeviceID)

    Log.info(Log.recorder, "recorder", "mic capture restarted after device change")
  }

  // MARK: - D12: Layered Mic Recovery

  /// Routes all three mic-reinstall trigger sources (AVAudioEngine notification,
  /// default-input listener, watchdog) through the same debounced path. Logs
  /// the source so we can tell from logs which layer actually saved a recording.
  private func requestMicReinstall(source: String) {
    guard phase != .stopped else { return }
    guard let engine = audioEngine else { return }
    Log.info(Log.recorder, "recorder", "mic reinstall requested (source=\(source))")
    debounceConfigChange(engine: engine)
  }

  /// Registers a CoreAudio listener on `kAudioHardwarePropertyDefaultInputDevice`.
  /// Catches same-format default-input switches that AVAudioEngine's own
  /// notification silently misses.
  private func installDefaultInputListener() {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain))
    let block: @Sendable (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void = {
      [weak self] _, _ in
      guard let self else { return }
      self.assumeIsolated { iso in
        guard iso.phase != .stopped else { return }
        iso.requestMicReinstall(source: "default_input_listener")
      }
    }
    defaultInputListenerBlock = block
    let status = AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &address, audioQueue, block)
    if status != noErr {
      Log.error(
        Log.recorder, "recorder",
        "failed to install default-input listener: OSStatus=\(status)")
      defaultInputListenerBlock = nil
    }
  }

  private func removeDefaultInputListener() {
    guard let block = defaultInputListenerBlock else { return }
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain))
    AudioObjectRemovePropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &address, audioQueue, block)
    defaultInputListenerBlock = nil
  }

  /// Buffer-arrival watchdog: trips when no mic buffers have arrived for
  /// `micStallThresholdSeconds`. Universal safety net for device-zoo
  /// failure modes (virtual drivers, in-place transport flips, silent
  /// DeviceIsAlive=false, unknown-unknowns).
  private func startMicWatchdog() {
    stopMicWatchdog()
    let timer = DispatchSource.makeTimerSource(queue: audioQueue)
    timer.schedule(
      deadline: .now() + .milliseconds(Int(Self.micWatchdogTickSeconds * 1000)),
      repeating: .milliseconds(Int(Self.micWatchdogTickSeconds * 1000)))
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      self.assumeIsolated { iso in
        iso.checkMicWatchdog()
      }
    }
    micWatchdogTimer = timer
    timer.resume()
  }

  private func stopMicWatchdog() {
    micWatchdogTimer?.cancel()
    micWatchdogTimer = nil
  }

  private func checkMicWatchdog() {
    guard phase != .stopped, audioEngine != nil else { return }
    let now = mach_absolute_time()
    guard now > lastMicHostTime else { return }
    let elapsedTicks = now - lastMicHostTime
    let elapsedNanos = AudioConvertHostTimeToNanos(elapsedTicks)
    let elapsedSeconds = Double(elapsedNanos) / 1_000_000_000
    guard elapsedSeconds > Self.micStallThresholdSeconds else { return }
    Log.error(
      Log.recorder, "recorder",
      "mic buffer stall: \(String(format: "%.2f", elapsedSeconds))s since last buffer")
    requestMicReinstall(source: "watchdog_mic_stall")
  }

  // MARK: - D9: Device Latency Offset

  /// Queries CoreAudio device latency properties for the input device and computes
  /// the total latency offset in seconds. Applied as PTS shift to mic samples.
  private func queryMicLatencyOffset(deviceID: AudioDeviceID) {
    let device = AudioHardwareDevice(id: deviceID)
    let inputLatency = (try? device.inputLatency) ?? 0
    let safetyOffset = (try? device.inputSafetyOffset) ?? 0
    let sampleRate = (try? device.nominalSampleRate) ?? 48000.0

    // Stream latency from first input stream
    let streamLatency: Int
    if let streams = try? device.streams,
      let inputStream = streams.first(where: { (try? $0.direction) == .input })
    {
      streamLatency = (try? inputStream.latency) ?? 0
    } else {
      streamLatency = 0
    }

    let totalFrames = inputLatency + streamLatency + safetyOffset
    micLatencyOffset = Double(totalFrames) / sampleRate
    micLatencyOffsetTicks =
      micLatencyOffset > 0 ? AudioConvertNanosToHostTime(UInt64(micLatencyOffset * 1e9)) : 0
    Log.info(
      Log.recorder, "recorder",
      "mic latency offset: \(totalFrames) frames (\(String(format: "%.1f", micLatencyOffset * 1000))ms) [device=\(inputLatency) stream=\(streamLatency) safety=\(safetyOffset)] at \(sampleRate)Hz"
    )
  }

  // MARK: - Drift Monitoring

  /// Logs the raw mic-vs-system `hostTime` delta every 5s. Only starts when mic
  /// is enabled - without a mic track there is nothing to compare against.
  private func startDriftMonitor() {
    driftStartHost = mach_absolute_time()
    lastMicHostTime = 0
    lastSystemHostTime = 0
    let timer = DispatchSource.makeTimerSource(queue: audioQueue)
    timer.schedule(deadline: .now() + 5, repeating: 5)
    let handler: @Sendable () -> Void = { [weak self] in
      guard let self else { return }
      self.assumeIsolated { iso in
        iso.logDrift()
      }
    }
    timer.setEventHandler(handler: handler)
    timer.resume()
    driftTimer = timer
  }

  private func logDrift() {
    guard phase != .stopped else { return }
    let now = mach_absolute_time()
    let elapsedMs = Double(AudioConvertHostTimeToNanos(now - driftStartHost)) / 1_000_000

    guard lastMicHostTime != 0, lastSystemHostTime != 0 else {
      Log.info(
        Log.recorder, "recorder",
        "drift: t=\(String(format: "%.1f", elapsedMs / 1000))s waiting (mic=\(lastMicHostTime != 0 ? "1" : "0") sys=\(lastSystemHostTime != 0 ? "1" : "0"))"
      )
      return
    }

    let nowNs = AudioConvertHostTimeToNanos(now)
    let micNs = AudioConvertHostTimeToNanos(lastMicHostTime)
    let sysNs = AudioConvertHostTimeToNanos(lastSystemHostTime)
    let micAgeMs = Double(Int64(nowNs) - Int64(micNs)) / 1_000_000
    let sysAgeMs = Double(Int64(nowNs) - Int64(sysNs)) / 1_000_000
    let deltaMs = Double(Int64(micNs) - Int64(sysNs)) / 1_000_000
    let d9Ms = micLatencyOffset * 1000

    Log.info(
      Log.recorder, "recorder",
      "drift: t=\(String(format: "%.1f", elapsedMs / 1000))s sys_age=\(String(format: "%.1f", sysAgeMs))ms mic_age=\(String(format: "%.1f", micAgeMs))ms mic-sys=\(String(format: "%+.1f", deltaMs))ms d9=\(String(format: "%.1f", d9Ms))ms"
    )
  }

  // MARK: - Disk Space Monitoring

  private func startDiskSpaceMonitor() {
    let timer = DispatchSource.makeTimerSource(queue: audioQueue)
    timer.schedule(deadline: .now() + 30, repeating: 30)
    let handler: @Sendable () -> Void = { [weak self] in
      guard let self else { return }
      self.assumeIsolated { iso in
        iso.checkDiskSpace()
      }
    }
    timer.setEventHandler(handler: handler)
    timer.resume()
    diskSpaceTimer = timer
  }

  private func checkDiskSpace() {
    guard phase != .stopped else { return }
    let attrs = try? FileManager.default.attributesOfFileSystem(forPath: saveDirectory.path)
    guard let freeBytes = attrs?[.systemFreeSize] as? Int64 else { return }

    if freeBytes < 100_000_000 {
      Log.error(Log.recorder, "recorder", "critical disk space (\(freeBytes) bytes), stopping")
      onFailure?(.lowDiskSpace)
    } else if freeBytes < 500_000_000, !lowDiskSpaceWarned {
      lowDiskSpaceWarned = true
      Log.info(Log.recorder, "recorder", "low disk space warning (\(freeBytes) bytes)")
      onLowDiskSpace?(freeBytes)
    }
  }

  /// Resolve CoreAudio device ID to its human-readable name.
  nonisolated private static func audioDeviceName(for deviceID: AudioDeviceID) -> String? {
    try? AudioHardwareDevice(id: deviceID).name
  }
}

// MARK: - SCStreamProxy

/// NSObject delegate/output for SCStream. Actors cannot inherit from NSObject,
/// so this thin proxy forwards callbacks into the actor. The sample handler runs
/// on `audioQueue` (the same executor the actor uses), so `assumeIsolated` bridges
/// synchronously. The delegate's `didStopWithError` may run on any queue, so it
/// hops through `audioQueue.async` first.
final class SCStreamProxy: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
  nonisolated(unsafe) weak var recorder: AudioRecorder?
  private let audioQueue: DispatchSerialQueue

  nonisolated init(audioQueue: DispatchSerialQueue) {
    self.audioQueue = audioQueue
    super.init()
  }

  nonisolated func stream(
    _ stream: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard type == .audio, let recorder else { return }
    // SCStream delivers on `audioQueue` (see `addStreamOutput(sampleHandlerQueue:)`),
    // which is the recorder actor's executor, so `assumeIsolated` is synchronous
    // and safe. `nonisolated(unsafe)` satisfies Swift 6's sending check across
    // the task-isolated → actor-isolated boundary.
    nonisolated(unsafe) let buffer = sampleBuffer
    recorder.assumeIsolated { iso in
      iso.handleSystemSampleBuffer(buffer)
    }
  }

  nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
    let code = (error as NSError).code
    let description = error.localizedDescription
    guard let recorder else { return }
    audioQueue.async { [weak recorder] in
      guard let recorder else { return }
      recorder.assumeIsolated { iso in
        iso.handleStreamStopped(code: code, description: description)
      }
    }
  }
}

// MARK: - PCM-to-CMSampleBuffer Conversion

extension AVAudioPCMBuffer {
  /// Converts AVAudioPCMBuffer to CMSampleBuffer for writing to AVAssetWriterInput.
  /// Reference: Apple Developer Forums thread 727709, aibo-cora gist.
  nonisolated func asSampleBuffer(timestamp: AVAudioTime? = nil) -> CMSampleBuffer? {
    let asbd = format.streamDescription
    var formatDescription: CMFormatDescription?

    guard
      CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        asbd: asbd,
        layoutSize: 0,
        layout: nil,
        magicCookieSize: 0,
        magicCookie: nil,
        extensions: nil,
        formatDescriptionOut: &formatDescription
      ) == noErr
    else { return nil }

    let pts: CMTime
    if let timestamp, timestamp.isHostTimeValid {
      pts = CMClockMakeHostTimeFromSystemUnits(timestamp.hostTime)
    } else {
      pts = CMClockGetTime(CMClockGetHostTimeClock())
    }

    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: Int32(asbd.pointee.mSampleRate)),
      presentationTimeStamp: pts,
      decodeTimeStamp: .invalid
    )

    var sampleBuffer: CMSampleBuffer?
    guard
      CMSampleBufferCreate(
        allocator: kCFAllocatorDefault,
        dataBuffer: nil,
        dataReady: false,
        makeDataReadyCallback: nil,
        refcon: nil,
        formatDescription: formatDescription,
        sampleCount: CMItemCount(frameLength),
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleSizeEntryCount: 0,
        sampleSizeArray: nil,
        sampleBufferOut: &sampleBuffer
      ) == noErr
    else { return nil }

    guard let sampleBuffer,
      CMSampleBufferSetDataBufferFromAudioBufferList(
        sampleBuffer,
        blockBufferAllocator: kCFAllocatorDefault,
        blockBufferMemoryAllocator: kCFAllocatorDefault,
        flags: 0,
        bufferList: mutableAudioBufferList
      ) == noErr
    else { return nil }

    return sampleBuffer
  }
}

// MARK: - Error Types

enum RecorderError: Error, LocalizedError {
  case noDisplay
  case permissionDenied
  case systemStopped
  case writerFailed
  case cancelled

  var errorDescription: String? {
    switch self {
    case .noDisplay: "No display found"
    case .permissionDenied: "Screen Recording permission denied"
    case .systemStopped: "System audio capture was stopped"
    case .writerFailed: "Failed to start audio writer"
    case .cancelled: "Recording start was cancelled"
    }
  }
}

/// Categorized runtime failures reported by AudioRecorder.
/// AudioMonitor uses these to decide recovery strategy.
enum RecorderFailure: Sendable {
  case systemStopped
  case permissionDenied
  case lowDiskSpace
  case other(String)
}
