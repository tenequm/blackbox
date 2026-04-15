@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import ObjCExceptionCatcher

/// Records system audio via CATap (CoreAudio Process Tap) and mic via AVAudioEngine
/// as independent pipelines.
///
/// Dual-track capture: system audio (CATap aggregate device IO proc) and mic (AVAudioEngine)
/// written as separate AVAssetWriterInputs to a single M4A file. No post-processing or mixing.
/// Uses a custom DispatchSerialQueue executor - all actor-isolated state is accessed on `audioQueue`.
///
/// AVAudioEngine handles mic device following automatically - on hardware change, the
/// `AVAudioEngineConfigurationChange` notification fires and the tap is reinstalled.
/// `movieFragmentInterval` ensures partial file recovery on crash.
actor AudioRecorder {
  nonisolated let bundleID: String?
  nonisolated let appName: String
  nonisolated let micEnabled: Bool
  nonisolated let saveDirectory: URL
  nonisolated let isManualRecording: Bool

  nonisolated let onFailure: (@Sendable (RecorderFailure) -> Void)?
  nonisolated let onAudioLevel: (@Sendable (Float) -> Void)?
  nonisolated let onLowDiskSpace: (@Sendable (Int64) -> Void)?
  nonisolated let onContinuityEvent: (@Sendable (RecorderContinuityEvent) -> Void)?

  private nonisolated let audioQueue = DispatchSerialQueue(
    label: "com.tenequm.blackbox.audio")
  nonisolated var unownedExecutor: UnownedSerialExecutor {
    audioQueue.asUnownedSerialExecutor()
  }

  // CATap state
  private var processTap: AudioHardwareTap?
  private var aggregateDevice: AudioHardwareAggregateDevice?
  private var ioProcID: AudioDeviceIOProcID?
  private var tapFormat: AVAudioFormat?
  private var outputDeviceListenerBlock: AudioObjectPropertyListenerBlock?
  private var rateChangeListenerBlock: AudioObjectPropertyListenerBlock?

  // AVAudioEngine
  private var audioEngine: AVAudioEngine?
  private var configChangeObserver: (any NSObjectProtocol)?

  // Writer state
  private var pipeline: RecordingPipeline?
  private var stopped = false
  private var activity: NSObjectProtocol?
  private var diskSpaceTimer: DispatchSourceTimer?
  private var lowDiskSpaceWarned = false
  private var micTapFormat: AVAudioFormat?
  private var micBuffersConversionFailed: Int = 0
  private var configChangeGeneration: Int = 0

  // D9: device latency offset for mic-system alignment
  private var micLatencyOffset: Double = 0

  // Drift monitor state. Raw (pre-D9) host times from the most recent buffer
  // delivered by each path, plus a 5s log timer. Used to surface mic-vs-system
  // clock skew or drift during a live recording.
  private var driftTimer: DispatchSourceTimer?
  private var lastMicHostTime: UInt64 = 0
  private var lastSystemHostTime: UInt64 = 0
  private var driftStartHost: UInt64 = 0

  init(
    bundleID: String? = nil, appName: String, micEnabled: Bool,
    saveDirectory: URL,
    isManualRecording: Bool = false,
    onFailure: (@Sendable (RecorderFailure) -> Void)? = nil,
    onAudioLevel: (@Sendable (Float) -> Void)? = nil,
    onLowDiskSpace: (@Sendable (Int64) -> Void)? = nil,
    onContinuityEvent: (@Sendable (RecorderContinuityEvent) -> Void)? = nil
  ) {
    self.bundleID = bundleID
    self.appName = appName
    self.micEnabled = micEnabled
    self.saveDirectory = saveDirectory
    self.isManualRecording = isManualRecording
    self.onFailure = onFailure
    self.onAudioLevel = onAudioLevel
    self.onLowDiskSpace = onLowDiskSpace
    self.onContinuityEvent = onContinuityEvent
  }

  deinit {
    if let configChangeObserver {
      NotificationCenter.default.removeObserver(configChangeObserver)
    }
    if let activity { ProcessInfo.processInfo.endActivity(activity) }
  }

  // MARK: - Start / Stop

  /// Starts capturing audio and writing to file immediately.
  func start() async throws {
    Log.recorder.info(
      "start() for \(self.appName, privacy: .public) (\(self.bundleID ?? "all", privacy: .public))")

    // 1. Get own PID's AudioObjectID via Swift wrapper
    let myPID = ProcessInfo.processInfo.processIdentifier
    let system = AudioHardwareSystem.shared
    guard let myProcess = try system.process(for: myPID) else {
      throw RecorderError.tapCreationFailed("own PID not found in CoreAudio")
    }

    // 2. Create CATapDescription excluding own PID (global stereo tap)
    let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [myProcess.id])
    tapDescription.uuid = UUID()

    // 3. Create process tap
    let tap: AudioHardwareTap
    do {
      guard let created = try system.makeProcessTap(description: tapDescription) else {
        throw RecorderError.tapCreationFailed("makeProcessTap returned nil")
      }
      tap = created
    } catch let error as RecorderError {
      throw error
    } catch {
      let audioError = error as? AudioHardwareError
      if audioError?.error == OSStatus(kAudioHardwareBadObjectError) {
        throw RecorderError.permissionDenied
      }
      throw RecorderError.tapCreationFailed("makeProcessTap failed: \(error)")
    }
    self.processTap = tap
    Log.info(Log.recorder, "recorder", "created process tap #\(tap.id)")

    // 4-6: Read tap format, output device, create aggregate. Clean up tap on any failure.
    let aggregateFormat: AVAudioFormat
    do {
      var streamDesc = try tap.format
      guard let tapFmt = AVAudioFormat(streamDescription: &streamDesc) else {
        throw RecorderError.tapCreationFailed("invalid tap stream format")
      }
      Log.info(
        Log.recorder, "recorder",
        "tap format: \(tapFmt.channelCount)ch, \(tapFmt.sampleRate)Hz, interleaved=\(tapFmt.isInterleaved)"
      )

      guard let outputDevice = try system.defaultOutputDevice else {
        throw RecorderError.tapCreationFailed("no default output device")
      }
      let outputUID = try outputDevice.uid

      let aggregate = try createAggregateDevice(
        system: system, outputUID: outputUID, tapUUID: tapDescription.uuid)
      self.aggregateDevice = aggregate
      Log.info(Log.recorder, "recorder", "created aggregate device #\(aggregate.id)")

      // Force 48kHz on aggregate device (Chromium's approach - prevents rate mismatch
      // when Bluetooth HFP or other non-48kHz devices pull the system audio graph rate)
      aggregateFormat = configureAggregateSampleRate(aggregate)
      self.tapFormat = aggregateFormat
    } catch {
      destroyTap()
      throw error
    }

    do {
      let pipeline = RecordingPipeline(
        bundleID: bundleID,
        appName: appName,
        micEnabled: micEnabled,
        saveDirectory: saveDirectory,
        alignmentMode: isManualRecording ? .preserveAllContent : .waitForAllTracks,
        onFailure: onFailure,
        onAudioLevel: onAudioLevel
      )
      try pipeline.start()
      self.pipeline = pipeline

      // 8. Create IO proc on aggregate device
      let capturedFormat = aggregateFormat
      let aggregate = self.aggregateDevice!
      let ioProcBlock = makeIOProcBlock(format: capturedFormat)
      let err = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregate.id, nil, ioProcBlock)
      guard err == noErr else {
        throw RecorderError.tapCreationFailed("AudioDeviceCreateIOProcIDWithBlock failed: \(err)")
      }

      // 9. Start IO proc
      activity = ProcessInfo.processInfo.beginActivity(
        options: .userInitiated,
        reason: "Recording call audio"
      )
      try aggregate.start(IOProcID: ioProcID)
      Log.info(Log.recorder, "recorder", "CATap started for \(appName)")
      startDiskSpaceMonitor()
      startDriftMonitor()
      installOutputDeviceListener()
      installRateChangeListener()

      // 10. Start mic capture independently - failure does not stop system audio
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
      stopMicCapture()
      removeRateChangeListener()
      removeOutputDeviceListener()
      destroyIOProc()
      destroyAggregateDevice()
      destroyTap()
      if let pipeline {
        _ = await pipeline.stop()
        self.pipeline = nil
      }
      if let activity {
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
      }
      throw error
    }
  }

  /// Stops capture and finalizes the recording file.
  @discardableResult
  func stop() async -> URL? {
    Log.recorder.info("stop() for \(self.appName, privacy: .public)")

    // Remove observer on MainActor (prevents new config change dispatches)
    if let observer = configChangeObserver {
      NotificationCenter.default.removeObserver(observer)
      configChangeObserver = nil
    }

    // CATap teardown (order matters per spec D5)
    removeRateChangeListener()
    removeOutputDeviceListener()
    destroyIOProc()
    destroyAggregateDevice()
    destroyTap()

    // Capture engine ref, clear property on MainActor
    let capturedEngine = audioEngine
    audioEngine = nil

    // All state mutations are actor-isolated (runs on audioQueue via custom executor)
    stopped = true

    // Mic teardown (serialized with config change handlers)
    if let engine = capturedEngine {
      var exc: NSException?
      if let inputNode = ObjCGetInputNode(engine, &exc) {
        let _ = ObjCRemoveTap(inputNode, 0)
      }
      let _ = ObjCStopEngine(engine)
    }

    let diagnostics = pipeline?.currentDiagnostics
    Log.info(
      Log.recorder, "recorder",
      "system stats: received=\(diagnostics?.systemBuffersReceived ?? 0) appended=\(diagnostics?.systemBuffersAppended ?? 0) notReady=\(diagnostics?.systemBuffersDroppedNotReady ?? 0) appendFail=\(diagnostics?.systemBuffersAppendFailed ?? 0) gapsFilled=\(diagnostics?.systemGapsFilled ?? 0) tailPad=\(String(format: "%.3f", diagnostics?.systemTailPaddingSeconds ?? 0))s"
    )
    if micEnabled {
      Log.info(
        Log.recorder, "recorder",
        "mic stats: received=\(diagnostics?.micBuffersReceived ?? 0) appended=\(diagnostics?.micBuffersAppended ?? 0) notReady=\(diagnostics?.micBuffersDroppedNotReady ?? 0) convFail=\(micBuffersConversionFailed) appendFail=\(diagnostics?.micBuffersAppendFailed ?? 0) gapsFilled=\(diagnostics?.micGapsFilled ?? 0) tailPad=\(String(format: "%.3f", diagnostics?.micTailPaddingSeconds ?? 0))s"
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
    micTapFormat = nil
    tapFormat = nil
    micLatencyOffset = 0
    let pipeline = self.pipeline
    self.pipeline = nil
    let savedURL = await pipeline?.stop()

    if let activity {
      ProcessInfo.processInfo.endActivity(activity)
      self.activity = nil
    }

    return savedURL
  }

  // MARK: - CATap Lifecycle Helpers

  private func destroyIOProc() {
    guard let ioProcID, let aggregate = aggregateDevice else { return }
    try? aggregate.stop(IOProcID: ioProcID)
    AudioDeviceDestroyIOProcID(aggregate.id, ioProcID)
    self.ioProcID = nil
  }

  private func destroyAggregateDevice() {
    guard let aggregate = aggregateDevice else { return }
    try? AudioHardwareSystem.shared.destroyAggregateDevice(aggregate)
    aggregateDevice = nil
  }

  private func destroyTap() {
    guard let tap = processTap else { return }
    try? AudioHardwareSystem.shared.destroyProcessTap(tap)
    processTap = nil
  }

  // MARK: - Output Device Change Listener

  private func installOutputDeviceListener() {
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      guard let self else { return }
      self.audioQueue.async { [weak self] in
        guard let self else { return }
        self.assumeIsolated { iso in
          iso.handleOutputDeviceChange()
        }
      }
    }
    AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &addr, audioQueue, block)
    outputDeviceListenerBlock = block
  }

  private func removeOutputDeviceListener() {
    guard let block = outputDeviceListenerBlock else { return }
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    AudioObjectRemovePropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &addr, audioQueue, block)
    outputDeviceListenerBlock = nil
  }

  // MARK: - Aggregate Device Helpers

  private func createAggregateDevice(
    system: AudioHardwareSystem, outputUID: String, tapUUID: UUID
  ) throws -> AudioHardwareAggregateDevice {
    let aggregateUID = UUID().uuidString
    let description: [String: Any] = [
      kAudioAggregateDeviceNameKey: "Blackbox-Tap",
      kAudioAggregateDeviceUIDKey: aggregateUID,
      kAudioAggregateDeviceMainSubDeviceKey: outputUID,
      kAudioAggregateDeviceIsPrivateKey: true,
      kAudioAggregateDeviceIsStackedKey: false,
      kAudioAggregateDeviceTapAutoStartKey: true,
      kAudioAggregateDeviceSubDeviceListKey: [
        [kAudioSubDeviceUIDKey: outputUID]
      ],
      kAudioAggregateDeviceTapListKey: [
        [
          kAudioSubTapDriftCompensationKey: true,
          kAudioSubTapUIDKey: tapUUID.uuidString,
        ]
      ],
    ]
    guard let aggregate = try system.makeAggregateDevice(description: description) else {
      throw RecorderError.tapCreationFailed("makeAggregateDevice returned nil")
    }
    return aggregate
  }

  /// Forces 48kHz on the aggregate device and returns an AVAudioFormat reflecting the confirmed rate.
  /// Logs initial, requested, and confirmed rates for diagnostics.
  private func configureAggregateSampleRate(
    _ aggregate: AudioHardwareAggregateDevice
  ) -> AVAudioFormat {
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyNominalSampleRate,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<Float64>.size)

    var initialRate: Float64 = 0
    AudioObjectGetPropertyData(aggregate.id, &addr, 0, nil, &size, &initialRate)

    var confirmedRate = initialRate
    if initialRate != 48000 {
      var targetRate: Float64 = 48000
      let setStatus = AudioObjectSetPropertyData(
        aggregate.id, &addr, 0, nil,
        UInt32(MemoryLayout<Float64>.size), &targetRate)
      // Read back to confirm
      AudioObjectGetPropertyData(aggregate.id, &addr, 0, nil, &size, &confirmedRate)
      Log.info(
        Log.recorder, "recorder",
        "aggregate device rate: initial=\(initialRate)Hz, requested=48000Hz, confirmed=\(confirmedRate)Hz, setStatus=\(setStatus)"
      )
    } else {
      Log.info(
        Log.recorder, "recorder",
        "aggregate device rate: \(confirmedRate)Hz (already 48kHz)")
    }

    // Build format from confirmed rate (not tap.format which may be stale)
    if let fmt = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: confirmedRate,
      channels: 2,
      interleaved: true)
    {
      return fmt
    }
    Log.error(
      Log.recorder, "recorder",
      "failed to create AVAudioFormat for \(confirmedRate)Hz, falling back to 48kHz")
    return AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true)!
  }

  // MARK: - Aggregate Device Rate Change Listener

  private func installRateChangeListener() {
    guard let aggregate = aggregateDevice else { return }
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyNominalSampleRate,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      guard let self else { return }
      self.assumeIsolated { iso in
        iso.handleRateChange()
      }
    }
    AudioObjectAddPropertyListenerBlock(aggregate.id, &addr, audioQueue, block)
    rateChangeListenerBlock = block
  }

  private func removeRateChangeListener() {
    guard let block = rateChangeListenerBlock, let aggregate = aggregateDevice else { return }
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyNominalSampleRate,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    AudioObjectRemovePropertyListenerBlock(aggregate.id, &addr, audioQueue, block)
    rateChangeListenerBlock = nil
  }

  private func handleRateChange() {
    guard !stopped, let aggregate = aggregateDevice else { return }
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyNominalSampleRate,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<Float64>.size)
    var currentRate: Float64 = 0
    AudioObjectGetPropertyData(aggregate.id, &addr, 0, nil, &size, &currentRate)

    let previousRate = tapFormat?.sampleRate ?? 0
    if currentRate != previousRate {
      Log.info(
        Log.recorder, "recorder",
        "aggregate device rate changed: \(previousRate)Hz -> \(currentRate)Hz")
      if let fmt = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: currentRate,
        channels: 2,
        interleaved: true)
      {
        tapFormat = fmt
      }
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

  /// Creates an IO proc callback block that copies audio data and dispatches to audioQueue.
  /// Used by both start() and handleOutputDeviceChange() to avoid duplication.
  nonisolated private func makeIOProcBlock(format: AVAudioFormat) -> AudioDeviceIOBlock {
    return { [weak self] _, inInputData, inInputTime, _, _ in
      guard let self else { return }
      guard
        let buffer = AVAudioPCMBuffer(
          pcmFormat: format, bufferListNoCopy: inInputData, deallocator: nil)
      else { return }
      let hostTime = inInputTime.pointee.mHostTime
      let audioTime = AVAudioTime(hostTime: hostTime)
      // Copy buffer data - IO proc buffer is only valid during callback
      guard
        let copy = AVAudioPCMBuffer(
          pcmFormat: format, frameCapacity: buffer.frameLength)
      else { return }
      copy.frameLength = buffer.frameLength
      if format.isInterleaved {
        let byteCount =
          Int(buffer.frameLength) * Int(format.channelCount)
          * MemoryLayout<Float>.size
        memcpy(copy.floatChannelData![0], buffer.floatChannelData![0], byteCount)
      } else {
        for ch in 0..<Int(format.channelCount) {
          let byteCount = Int(buffer.frameLength) * MemoryLayout<Float>.size
          memcpy(copy.floatChannelData![ch], buffer.floatChannelData![ch], byteCount)
        }
      }
      self.audioQueue.async { [weak self] in
        guard let self else { return }
        self.assumeIsolated { iso in
          iso.lastSystemHostTime = hostTime
          let actualRate = iso.tapFormat?.sampleRate ?? 48000
          guard let monoBuf = RecordingPipeline.resampleToMono48k(copy, sourceRate: actualRate),
            let sampleBuffer = monoBuf.asSampleBuffer(timestamp: audioTime)
          else { return }
          iso.handleSystemSample(sampleBuffer)
        }
      }
    }
  }

  /// Rebuilds aggregate device and IO proc when system output device changes.
  /// Gap during rebuild is handled by D8 silence gap filling.
  private func handleOutputDeviceChange() {
    guard !stopped else { return }
    onContinuityEvent?(.outputDeviceChanged)
    Log.info(Log.recorder, "recorder", "output device changed, rebuilding aggregate device")

    let system = AudioHardwareSystem.shared

    // Tear down IO proc, aggregate, and tap - recreate all with new output device
    removeRateChangeListener()
    destroyIOProc()
    destroyAggregateDevice()
    destroyTap()

    // Read new output device
    guard let outputDevice = try? system.defaultOutputDevice,
      let outputUID = try? outputDevice.uid
    else {
      Log.error(Log.recorder, "recorder", "failed to read new output device after change")
      onFailure?(.systemStopped)
      return
    }

    // Recreate process tap
    let myPID = ProcessInfo.processInfo.processIdentifier
    guard let myProcess = try? system.process(for: myPID) else {
      Log.error(Log.recorder, "recorder", "PID translation failed during device change")
      onFailure?(.systemStopped)
      return
    }

    let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [myProcess.id])
    tapDescription.uuid = UUID()

    guard let newTap = try? system.makeProcessTap(description: tapDescription) else {
      Log.error(Log.recorder, "recorder", "process tap recreation failed during device change")
      onFailure?(.systemStopped)
      return
    }
    self.processTap = newTap

    // Recreate aggregate device
    guard
      let aggregate = try? createAggregateDevice(
        system: system, outputUID: outputUID, tapUUID: tapDescription.uuid)
    else {
      Log.error(
        Log.recorder, "recorder",
        "aggregate device recreation failed during device change")
      destroyTap()
      onFailure?(.systemStopped)
      return
    }
    self.aggregateDevice = aggregate

    // Force 48kHz and use confirmed rate for IO proc
    let confirmedFormat = configureAggregateSampleRate(aggregate)
    self.tapFormat = confirmedFormat

    // Recreate IO proc using confirmed format
    let ioProcBlock = makeIOProcBlock(format: confirmedFormat)
    let err = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregate.id, nil, ioProcBlock)
    guard err == noErr else {
      Log.error(
        Log.recorder, "recorder", "IO proc recreation failed during device change: \(err)")
      destroyAggregateDevice()
      destroyTap()
      onFailure?(.systemStopped)
      return
    }

    do {
      try aggregate.start(IOProcID: ioProcID)
    } catch {
      Log.error(
        Log.recorder, "recorder", "AudioDeviceStart failed during device change: \(error)")
      destroyIOProc()
      destroyAggregateDevice()
      destroyTap()
      onFailure?(.systemStopped)
      return
    }

    installRateChangeListener()
    Log.info(
      Log.recorder, "recorder",
      "aggregate device rebuilt after output device change (new output: \(outputUID))")
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
    micTapFormat = nativeFormat
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

    // D9: query initial mic latency offset
    queryMicLatencyOffset(deviceID: inputDeviceID)

    let capturedEngine = engine
    configChangeObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange,
      object: engine,
      queue: nil
    ) { [weak self] _ in
      guard let self else { return }
      Task { await self.debounceConfigChange(engine: capturedEngine) }
    }

    Log.info(
      Log.recorder, "recorder",
      "mic capture started via AVAudioEngine (format: \(nativeFormat), resample: \(nativeFormat.sampleRate != 48000))"
    )
  }

  private func stopMicCapture() {
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

  /// Handles mic audio buffer on audioQueue.
  private func handleMicBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
    guard !stopped else { return }
    if time.isHostTimeValid {
      lastMicHostTime = time.hostTime
    }

    // D9: apply latency offset once, used for both session start and buffer conversion
    let adjustedTime: AVAudioTime
    if micLatencyOffset > 0, time.isHostTimeValid {
      let offsetTicks = AudioConvertNanosToHostTime(UInt64(micLatencyOffset * 1e9))
      let adjustedHostTime =
        time.hostTime > offsetTicks ? time.hostTime - offsetTicks : time.hostTime
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
      Log.recorder.warning("mic PCM-to-CMSampleBuffer conversion failed")
      return
    }
    pipeline?.appendMicSample(sampleBuffer)
  }

  /// Debounces rapid config change notifications (e.g. Krisp device switching).
  /// Dispatches to audioQueue with 300ms delay; only the last notification fires.
  private func debounceConfigChange(engine: AVAudioEngine) {
    configChangeGeneration += 1
    let gen = configChangeGeneration
    audioQueue.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
      guard let self else { return }
      self.assumeIsolated { iso in
        guard !iso.stopped, iso.configChangeGeneration == gen else { return }
        iso.handleEngineConfigChange(engine: engine)
      }
    }
  }

  /// Handles AVAudioEngine configuration change (device plugged/unplugged).
  /// Runs on audioQueue to serialize with stopped flag and buffer handling.
  /// Reinstalls tap and restarts engine. System audio continues regardless.
  private func handleEngineConfigChange(engine: AVAudioEngine) {
    guard !stopped else { return }
    onContinuityEvent?(.micConfigurationChanged)
    Log.info(Log.recorder, "recorder", "audio engine config changed, restarting mic capture")

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
    Log.info(
      Log.recorder, "recorder",
      "mic latency offset: \(totalFrames) frames (\(String(format: "%.1f", micLatencyOffset * 1000))ms) [device=\(inputLatency) stream=\(streamLatency) safety=\(safetyOffset)] at \(sampleRate)Hz"
    )
  }

  // MARK: - Drift Monitoring

  /// Logs the raw mic-vs-system `hostTime` delta every 5s. Raw (pre-D9) values
  /// are used so we see the actual hardware offset and can judge whether D9 is
  /// under- or over-compensating, and whether the two clocks drift over time.
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
    guard !stopped else { return }
    let now = mach_absolute_time()
    let elapsedMs = Double(AudioConvertHostTimeToNanos(now - driftStartHost)) / 1_000_000

    let micReady = lastMicHostTime != 0
    let sysReady = lastSystemHostTime != 0
    guard micReady || sysReady else {
      Log.info(
        Log.recorder, "recorder",
        "drift: t=\(String(format: "%.1f", elapsedMs / 1000))s waiting for both streams")
      return
    }
    guard micReady, sysReady else {
      Log.info(
        Log.recorder, "recorder",
        "drift: t=\(String(format: "%.1f", elapsedMs / 1000))s only \(micReady ? "mic" : "sys") firing"
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
    guard !stopped else { return }
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

// MARK: - System Audio Handling

extension AudioRecorder {
  private func handleSystemSample(_ sampleBuffer: CMSampleBuffer) {
    guard !stopped else { return }
    pipeline?.appendSystemSample(sampleBuffer)
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
  case permissionDenied
  case writerFailed
  case tapCreationFailed(String)

  var errorDescription: String? {
    switch self {
    case .permissionDenied: "System audio recording permission denied"
    case .writerFailed: "Failed to start audio writer"
    case .tapCreationFailed(let detail): "Audio tap setup failed: \(detail)"
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
