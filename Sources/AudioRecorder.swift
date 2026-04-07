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

  nonisolated let onFailure: (@Sendable (RecorderFailure) -> Void)?
  nonisolated let onAudioLevel: (@Sendable (Float) -> Void)?
  nonisolated let onLowDiskSpace: (@Sendable (Int64) -> Void)?

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

  // AVAudioEngine
  private var audioEngine: AVAudioEngine?
  private var configChangeObserver: (any NSObjectProtocol)?

  // Writer state
  private var writer: AVAssetWriter?
  private var systemAudioInput: AVAssetWriterInput?
  private var micInput: AVAssetWriterInput?
  private var sessionStarted = false
  private var stopped = false
  private var audioFileURL: URL?
  private var fileURL: URL?  // recording directory URL
  private var activity: NSObjectProtocol?
  private var lastLevelTime: UInt64 = 0
  private var pendingMaxLevel: Float = 0
  private var writerFailureReported = false
  private var diskSpaceTimer: DispatchSourceTimer?
  private var lowDiskSpaceWarned = false
  private var micTapFormat: AVAudioFormat?
  private var micBuffersReceived: Int = 0
  private var micBuffersAppended: Int = 0
  private var micBuffersDroppedPreSession: Int = 0
  private var micBuffersDroppedNotReady: Int = 0
  private var micBuffersConversionFailed: Int = 0
  private var micBuffersAppendFailed: Int = 0
  private var micPeakLevel: Float = 0
  private var configChangeGeneration: Int = 0

  // System audio stats
  private var systemBuffersReceived: Int = 0
  private var systemBuffersAppended: Int = 0
  private var systemBuffersDroppedNotReady: Int = 0
  private var systemBuffersAppendFailed: Int = 0
  private var systemPeakLevel: Float = 0

  // Gap filling state - per pipeline (D8: silence gap filling)
  private var systemNextExpected: CMTime = .invalid
  private var systemGapsFilled: Int = 0
  private var micNextExpected: CMTime = .invalid
  private var micGapsFilled: Int = 0

  // D9: device latency offset for mic-system alignment
  private var micLatencyOffset: Double = 0

  init(
    bundleID: String? = nil, appName: String, micEnabled: Bool,
    saveDirectory: URL,
    onFailure: (@Sendable (RecorderFailure) -> Void)? = nil,
    onAudioLevel: (@Sendable (Float) -> Void)? = nil,
    onLowDiskSpace: (@Sendable (Int64) -> Void)? = nil
  ) {
    self.bundleID = bundleID
    self.appName = appName
    self.micEnabled = micEnabled
    self.saveDirectory = saveDirectory
    self.onFailure = onFailure
    self.onAudioLevel = onAudioLevel
    self.onLowDiskSpace = onLowDiskSpace
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
    let format: AVAudioFormat
    do {
      var streamDesc = try tap.format
      guard let fmt = AVAudioFormat(streamDescription: &streamDesc) else {
        throw RecorderError.tapCreationFailed("invalid tap stream format")
      }
      format = fmt
      self.tapFormat = format
      Log.info(
        Log.recorder, "recorder",
        "tap format: \(format.channelCount)ch, \(format.sampleRate)Hz, interleaved=\(format.isInterleaved)"
      )

      guard let outputDevice = try system.defaultOutputDevice else {
        throw RecorderError.tapCreationFailed("no default output device")
      }
      let outputUID = try outputDevice.uid

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
            kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
          ]
        ],
      ]
      guard let aggregate = try system.makeAggregateDevice(description: description) else {
        throw RecorderError.tapCreationFailed("makeAggregateDevice returned nil")
      }
      self.aggregateDevice = aggregate
      Log.info(Log.recorder, "recorder", "created aggregate device #\(aggregate.id)")
    } catch {
      destroyTap()
      throw error
    }

    do {
      // 7. Setup writer (2-track)
      try setupWriter()

      // 8. Create IO proc on aggregate device
      let capturedFormat = format
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
      installOutputDeviceListener()

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
      removeOutputDeviceListener()
      destroyIOProc()
      destroyAggregateDevice()
      destroyTap()
      writer?.cancelWriting()
      if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
      writer = nil
      systemAudioInput = nil
      micInput = nil
      audioFileURL = nil
      fileURL = nil
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

    Log.info(
      Log.recorder, "recorder",
      "system stats: received=\(systemBuffersReceived) appended=\(systemBuffersAppended) notReady=\(systemBuffersDroppedNotReady) appendFail=\(systemBuffersAppendFailed) peakLevel=\(String(format: "%.6f", systemPeakLevel)) gapsFilled=\(systemGapsFilled)"
    )
    if micEnabled {
      Log.info(
        Log.recorder, "recorder",
        "mic stats: received=\(micBuffersReceived) appended=\(micBuffersAppended) preSession=\(micBuffersDroppedPreSession) notReady=\(micBuffersDroppedNotReady) convFail=\(micBuffersConversionFailed) appendFail=\(micBuffersAppendFailed) peakLevel=\(String(format: "%.6f", micPeakLevel)) gapsFilled=\(micGapsFilled)"
      )
    }
    let wasStarted = sessionStarted
    let capturedWriter = writer
    let capturedFileURL = fileURL
    diskSpaceTimer?.cancel()
    diskSpaceTimer = nil
    lowDiskSpaceWarned = false
    systemAudioInput?.markAsFinished()
    micInput?.markAsFinished()
    systemAudioInput = nil
    micInput = nil
    writer = nil
    sessionStarted = false
    micTapFormat = nil
    tapFormat = nil
    micLatencyOffset = 0
    audioFileURL = nil
    fileURL = nil

    var savedURL: URL?
    if let capturedWriter {
      if !wasStarted {
        capturedWriter.cancelWriting()
        if let capturedFileURL { try? FileManager.default.removeItem(at: capturedFileURL) }
      } else {
        nonisolated(unsafe) let writerForTimeout = capturedWriter
        let timeoutTask = Task.detached {
          try await Task.sleep(for: .seconds(5))
          Log.error(Log.recorder, "recorder", "finishWriting timed out after 5s, cancelling")
          writerForTimeout.cancelWriting()
        }
        await capturedWriter.finishWriting()
        timeoutTask.cancel()

        if capturedWriter.status == .failed {
          Log.error(
            Log.recorder, "recorder",
            "writer failed: \(capturedWriter.error?.localizedDescription ?? "unknown")")
        } else if capturedWriter.status == .cancelled {
          Log.error(
            Log.recorder, "recorder",
            "finishWriting cancelled by timeout - file may be incomplete")
        }
        // .cancelled with movieFragmentInterval still produces a playable file
        if capturedWriter.status == .completed || capturedWriter.status == .cancelled {
          savedURL = capturedFileURL
        }
      }
    }

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
          guard let sampleBuffer = copy.asSampleBuffer(timestamp: audioTime) else { return }
          iso.handleSystemSample(sampleBuffer)
        }
      }
    }
  }

  /// Rebuilds aggregate device and IO proc when system output device changes.
  /// Gap during rebuild is handled by D8 silence gap filling.
  private func handleOutputDeviceChange() {
    guard !stopped else { return }
    Log.info(Log.recorder, "recorder", "output device changed, rebuilding aggregate device")

    let system = AudioHardwareSystem.shared

    // Tear down IO proc, aggregate, and tap - recreate all with new output device
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

    // Read new tap format (may differ if output device changed sample rate)
    guard var newStreamDesc = try? newTap.format,
      let newFormat = AVAudioFormat(streamDescription: &newStreamDesc)
    else {
      Log.error(Log.recorder, "recorder", "failed to read tap format during device change")
      destroyTap()
      onFailure?(.systemStopped)
      return
    }
    self.tapFormat = newFormat

    // Recreate aggregate device
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
          kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
        ]
      ],
    ]
    guard let aggregate = try? system.makeAggregateDevice(description: description) else {
      Log.error(
        Log.recorder, "recorder",
        "aggregate device recreation failed during device change")
      destroyTap()
      onFailure?(.systemStopped)
      return
    }
    self.aggregateDevice = aggregate

    // Recreate IO proc using shared helper
    let ioProcBlock = makeIOProcBlock(format: newFormat)
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
    let tapHandler: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = {
      [weak self] buffer, when in
      guard let self else { return }
      self.audioQueue.async { [weak self] in
        guard let self else { return }
        self.assumeIsolated { iso in
          iso.handleMicBuffer(buffer, at: when)
        }
      }
    }

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
    micBuffersReceived += 1
    guard !stopped else { return }
    if !sessionStarted {
      guard let w = writer else { return }
      let adjustedTime: AVAudioTime
      if micLatencyOffset > 0, time.isHostTimeValid {
        let offsetTicks = AudioConvertNanosToHostTime(UInt64(micLatencyOffset * 1e9))
        let adjustedHostTime =
          time.hostTime > offsetTicks ? time.hostTime - offsetTicks : time.hostTime
        adjustedTime = AVAudioTime(hostTime: adjustedHostTime)
      } else {
        adjustedTime = time
      }
      let pts = CMClockMakeHostTimeFromSystemUnits(adjustedTime.hostTime)
      w.startSession(atSourceTime: pts)
      sessionStarted = true
    }
    // Resample to 48kHz if device rate differs (e.g. 24kHz AirPods).
    // Linear interpolation - adequate for voice audio, avoids AVAudioConverter @Sendable issues.
    let outputBuffer: AVAudioPCMBuffer
    if buffer.format.sampleRate != 48000 {
      let ratio = 48000.0 / buffer.format.sampleRate
      let outFrames = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio))
      guard let outFmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1),
        let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outFrames),
        let inData = buffer.floatChannelData?[0],
        let outData = outBuf.floatChannelData?[0]
      else {
        micBuffersConversionFailed += 1
        return
      }
      let inCount = Int(buffer.frameLength)
      for i in 0..<Int(outFrames) {
        let srcIdx = Double(i) / ratio
        let lo = Int(srcIdx)
        let hi = min(lo + 1, inCount - 1)
        let frac = Float(srcIdx - Double(lo))
        outData[i] = inData[lo] * (1 - frac) + inData[hi] * frac
      }
      outBuf.frameLength = outFrames
      outputBuffer = outBuf
    } else {
      outputBuffer = buffer
    }

    // D9: adjust mic timestamp by device latency offset before conversion
    let adjustedTime: AVAudioTime
    if micLatencyOffset > 0, time.isHostTimeValid {
      let offsetTicks = AudioConvertNanosToHostTime(UInt64(micLatencyOffset * 1e9))
      let adjustedHostTime =
        time.hostTime > offsetTicks ? time.hostTime - offsetTicks : time.hostTime
      adjustedTime = AVAudioTime(hostTime: adjustedHostTime)
    } else {
      adjustedTime = time
    }

    guard let sampleBuffer = outputBuffer.asSampleBuffer(timestamp: adjustedTime) else {
      micBuffersConversionFailed += 1
      Log.recorder.warning("mic PCM-to-CMSampleBuffer conversion failed")
      return
    }

    let pts = sampleBuffer.presentationTimeStamp
    let endTime = Self.bufferEndTime(sampleBuffer)
    if micNextExpected.isValid {
      let gap = CMTimeGetSeconds(pts - micNextExpected)
      if gap > 0.01, let input = micInput {
        let filled = fillGap(
          from: micNextExpected, to: pts,
          channelCount: 1, sampleRate: 48000, input: input)
        if filled > 0 {
          micGapsFilled += filled
          Log.info(
            Log.recorder, "recorder",
            "mic: filled \(String(format: "%.3f", gap))s gap with \(filled) silence buffers")
        }
      }
    }
    micNextExpected = endTime

    guard let input = micInput, input.isReadyForMoreMediaData else {
      micBuffersDroppedNotReady += 1
      return
    }
    if input.append(sampleBuffer) {
      micBuffersAppended += 1
    } else {
      micBuffersAppendFailed += 1
      Log.recorder.warning("mic append failed for \(self.appName, privacy: .public)")
    }
    publishAudioLevel(sampleBuffer, peak: &micPeakLevel)
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

    let tapHandler: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = {
      [weak self] buffer, when in
      guard let self else { return }
      self.audioQueue.async { [weak self] in
        guard let self else { return }
        self.assumeIsolated { iso in
          iso.handleMicBuffer(buffer, at: when)
        }
      }
    }

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

  // MARK: - Writer Setup

  private func setupWriter() throws {
    try FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)

    let attrs = try FileManager.default.attributesOfFileSystem(forPath: saveDirectory.path)
    if let freeBytes = attrs[.systemFreeSize] as? Int64, freeBytes < 50_000_000 {
      throw NSError(
        domain: "Blackbox", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Not enough disk space to start recording"])
    }

    let now = Date()
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    let suffix = UUID().uuidString.prefix(4)
    let dirName = "\(formatter.string(from: now))-\(suffix)"
    let dirURL = saveDirectory.appendingPathComponent(dirName)
    try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

    let audioURL = dirURL.appendingPathComponent("audio.m4a")
    Log.recorder.info("writing to \(dirName, privacy: .public)/audio.m4a")

    let trackCount = 1 + (micEnabled ? 1 : 0)
    let metadata = RecordingMetadata(
      title: appName,
      createdAt: now,
      appName: appName,
      speakers: [:],
      perAppBundleID: bundleID,
      perAppName: nil,
      trackCount: trackCount
    )
    try metadata.save(in: dirURL)

    let systemAudioSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 48000.0,
      AVNumberOfChannelsKey: 2,
      AVEncoderBitRateKey: 128_000,
    ]

    let micAudioSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 48000.0,
      AVNumberOfChannelsKey: 1,
      AVEncoderBitRateKey: 64_000,
    ]

    let newWriter = try AVAssetWriter(url: audioURL, fileType: .m4a)
    newWriter.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)

    // Track 0: system audio (always)
    let systemInput = AVAssetWriterInput(
      mediaType: .audio, outputSettings: systemAudioSettings)
    systemInput.expectsMediaDataInRealTime = true
    newWriter.add(systemInput)

    // Track 1: mic (when enabled)
    var newMicInput: AVAssetWriterInput?
    if micEnabled {
      let mi = AVAssetWriterInput(mediaType: .audio, outputSettings: micAudioSettings)
      mi.expectsMediaDataInRealTime = true
      newWriter.add(mi)
      newMicInput = mi
    }

    guard newWriter.startWriting() else {
      let err = newWriter.error
      Log.error(
        Log.recorder, "recorder",
        "writer startWriting failed: \(err?.localizedDescription ?? "unknown")")
      try? FileManager.default.removeItem(at: dirURL)
      throw err ?? RecorderError.writerFailed
    }

    writer = newWriter
    systemAudioInput = systemInput
    micInput = newMicInput
    audioFileURL = audioURL
    fileURL = dirURL
    sessionStarted = false
    stopped = false
    writerFailureReported = false
    micBuffersReceived = 0
    micBuffersAppended = 0
    micBuffersDroppedPreSession = 0
    micBuffersDroppedNotReady = 0
    micBuffersConversionFailed = 0
    micBuffersAppendFailed = 0
    micPeakLevel = 0
    configChangeGeneration = 0
    systemBuffersReceived = 0
    systemBuffersAppended = 0
    systemBuffersDroppedNotReady = 0
    systemBuffersAppendFailed = 0
    systemPeakLevel = 0
    systemNextExpected = .invalid
    systemGapsFilled = 0
    micNextExpected = .invalid
    micGapsFilled = 0
  }

  /// Resolve CoreAudio device ID to its human-readable name.
  nonisolated private static func audioDeviceName(for deviceID: AudioDeviceID) -> String? {
    try? AudioHardwareDevice(id: deviceID).name
  }
}

// MARK: - System Audio Handling

extension AudioRecorder {
  private func handleSystemSample(_ sampleBuffer: CMSampleBuffer) {
    systemBuffersReceived += 1
    guard !stopped else { return }

    if !sessionStarted {
      writer?.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
      sessionStarted = true
    }

    let pts = sampleBuffer.presentationTimeStamp
    let endTime = Self.bufferEndTime(sampleBuffer)
    if systemNextExpected.isValid {
      let gap = CMTimeGetSeconds(pts - systemNextExpected)
      if gap > 0.01, let input = systemAudioInput {
        let filled = fillGap(
          from: systemNextExpected, to: pts,
          channelCount: 2, sampleRate: 48000, input: input)
        if filled > 0 {
          systemGapsFilled += filled
          Log.info(
            Log.recorder, "recorder",
            "system: filled \(String(format: "%.3f", gap))s gap with \(filled) silence buffers")
        }
      }
    }
    systemNextExpected = endTime

    guard let input = systemAudioInput, input.isReadyForMoreMediaData else {
      systemBuffersDroppedNotReady += 1
      return
    }

    if input.append(sampleBuffer) {
      systemBuffersAppended += 1
    } else {
      systemBuffersAppendFailed += 1
      Log.recorder.warning("system audio append failed for \(self.appName, privacy: .public)")
      if !writerFailureReported, let w = writer, w.status == .failed {
        writerFailureReported = true
        let desc = w.error?.localizedDescription ?? "unknown writer error"
        Log.error(Log.recorder, "recorder", "writer entered failed state: \(desc)")
        onFailure?(.other(desc))
      }
    }

    publishAudioLevel(sampleBuffer, peak: &systemPeakLevel)
  }

  // MARK: - Peak Level Tracking

  /// Compute RMS audio level from a sample buffer and publish via callback.
  /// Both system audio and mic call this. Max level is accumulated between
  /// publishes so neither source drowns out the other. Throttled to ~4Hz.
  /// Optionally tracks peak level in a single pass (avoids double buffer scan).
  private func publishAudioLevel(
    _ sampleBuffer: CMSampleBuffer, peak: inout Float
  ) {
    guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
    var length = 0
    var dataPointer: UnsafeMutablePointer<Int8>?
    guard
      CMBlockBufferGetDataPointer(
        blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
        totalLengthOut: &length, dataPointerOut: &dataPointer) == noErr,
      let dataPointer, length > 0
    else { return }

    let floatCount = length / MemoryLayout<Float>.size
    guard floatCount > 0 else { return }
    let samples = UnsafeBufferPointer(
      start: UnsafeRawPointer(dataPointer).assumingMemoryBound(to: Float.self),
      count: floatCount
    )
    var sumOfSquares: Float = 0
    for sample in samples {
      let abs = Swift.abs(sample)
      if abs > peak { peak = abs }
      sumOfSquares += sample * sample
    }

    guard onAudioLevel != nil else { return }
    let rms = (sumOfSquares / Float(floatCount)).squareRoot()
    if rms > pendingMaxLevel { pendingMaxLevel = rms }

    let now = DispatchTime.now().uptimeNanoseconds
    guard now - lastLevelTime >= 250_000_000 else { return }
    lastLevelTime = now
    let level = pendingMaxLevel
    pendingMaxLevel = 0
    onAudioLevel?(level)
  }
}

// MARK: - Gap Filling (D8)

extension AudioRecorder {
  /// Computes the end time (PTS + total duration) of a sample buffer.
  nonisolated static func bufferEndTime(_ sampleBuffer: CMSampleBuffer) -> CMTime {
    let pts = sampleBuffer.presentationTimeStamp
    let dur = sampleBuffer.duration
    if dur.isValid && !dur.isIndefinite {
      return CMTimeAdd(pts, dur)
    }
    guard let fd = sampleBuffer.formatDescription else { return .invalid }
    let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)
    guard let rate = asbd?.pointee.mSampleRate, rate > 0 else { return .invalid }
    let n = sampleBuffer.numSamples
    return CMTimeAdd(pts, CMTime(value: Int64(n), timescale: Int32(rate)))
  }

  /// Fills a PTS gap with silence buffers to prevent AVAssetWriter from collapsing the timeline.
  /// Best-effort: logs and stops on failure without affecting the real audio pipeline.
  /// Returns number of silence buffers written.
  private func fillGap(
    from start: CMTime, to end: CMTime,
    channelCount: Int,
    sampleRate: Double,
    input: AVAssetWriterInput
  ) -> Int {
    let gapSeconds = CMTimeGetSeconds(end - start)
    let gapSamples = Int(gapSeconds * sampleRate)
    guard gapSamples > 0 else { return 0 }

    let chunkSize = 1024
    var written = 0
    var offset = 0

    while offset < gapSamples {
      let count = min(chunkSize, gapSamples - offset)
      let pts = CMTimeAdd(start, CMTime(value: Int64(offset), timescale: Int32(sampleRate)))

      guard
        let sb = Self.makeSilentSampleBuffer(
          channelCount: channelCount,
          sampleCount: count,
          sampleRate: sampleRate,
          presentationTimeStamp: pts
        )
      else {
        Log.error(
          Log.recorder, "recorder",
          "silence buffer creation failed at offset \(offset)/\(gapSamples)")
        break
      }

      guard input.isReadyForMoreMediaData else {
        Log.info(
          Log.recorder, "recorder",
          "silence fill interrupted by back-pressure at \(written)/\(gapSamples / chunkSize) chunks"
        )
        break
      }
      if input.append(sb) {
        written += 1
      } else {
        Log.error(
          Log.recorder, "recorder",
          "silence append failed at offset \(offset)/\(gapSamples)")
        break
      }
      offset += count
    }

    return written
  }

  /// Creates a zero-filled (silent) CMSampleBuffer with a clean LPCM format description.
  /// Builds its own ASBD from scratch rather than reusing pipeline format descriptions,
  /// which may carry extensions that cause AVAssetWriter failures (D8).
  nonisolated static func makeSilentSampleBuffer(
    channelCount: Int,
    sampleCount: Int,
    sampleRate: Double,
    presentationTimeStamp: CMTime
  ) -> CMSampleBuffer? {
    let bytesPerSample = MemoryLayout<Float>.size * channelCount
    let dataSize = sampleCount * bytesPerSample

    // Build clean LPCM format description - Float32, packed, interleaved, no extensions
    var asbd = AudioStreamBasicDescription(
      mSampleRate: sampleRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
      mBytesPerPacket: UInt32(bytesPerSample),
      mFramesPerPacket: 1,
      mBytesPerFrame: UInt32(bytesPerSample),
      mChannelsPerFrame: UInt32(channelCount),
      mBitsPerChannel: 32,
      mReserved: 0
    )
    var formatDescription: CMFormatDescription?
    guard
      CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        asbd: &asbd,
        layoutSize: 0, layout: nil,
        magicCookieSize: 0, magicCookie: nil,
        extensions: nil,
        formatDescriptionOut: &formatDescription
      ) == noErr, let formatDescription
    else { return nil }

    var blockBuffer: CMBlockBuffer?
    guard
      CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,
        blockLength: dataSize,
        blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: dataSize,
        flags: kCMBlockBufferAssureMemoryNowFlag,
        blockBufferOut: &blockBuffer
      ) == noErr, let blockBuffer
    else { return nil }

    guard
      CMBlockBufferFillDataBytes(
        with: 0, blockBuffer: blockBuffer,
        offsetIntoDestination: 0, dataLength: dataSize
      ) == noErr
    else { return nil }

    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: Int32(sampleRate)),
      presentationTimeStamp: presentationTimeStamp,
      decodeTimeStamp: .invalid
    )

    var sampleSize = bytesPerSample
    var sampleBuffer: CMSampleBuffer?
    guard
      CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault,
        dataBuffer: blockBuffer,
        formatDescription: formatDescription,
        sampleCount: sampleCount,
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleSizeEntryCount: 1,
        sampleSizeArray: &sampleSize,
        sampleBufferOut: &sampleBuffer
      ) == noErr
    else { return nil }

    return sampleBuffer
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
