@preconcurrency import AVFoundation
import AudioToolbox
import ObjCExceptionCatcher

/// Records system audio via CATap (CoreAudio Process Tap) and mic via AVAudioEngine
/// as independent pipelines.
///
/// Dual-track capture: system audio (CATap aggregate device IO proc) and mic (AVAudioEngine)
/// written as separate AVAssetWriterInputs to a single M4A file. No post-processing or mixing.
/// All mutable recording state is accessed exclusively from `audioQueue` (a serial dispatch queue).
/// `stop()` dispatches teardown onto `audioQueue` to serialize with callbacks, then awaits the writer.
///
/// AVAudioEngine handles mic device following automatically - on hardware change, the
/// `AVAudioEngineConfigurationChange` notification fires and the tap is reinstalled.
/// `movieFragmentInterval` ensures partial file recovery on crash.
final class AudioRecorder: NSObject, @unchecked Sendable {
  nonisolated let bundleID: String?
  nonisolated let appName: String
  nonisolated let micEnabled: Bool
  nonisolated let saveDirectory: URL

  nonisolated let onFailure: (@Sendable (RecorderFailure) -> Void)?
  nonisolated let onAudioLevel: (@Sendable (Float) -> Void)?
  nonisolated let onLowDiskSpace: (@Sendable (Int64) -> Void)?

  private let audioQueue = DispatchQueue(label: "com.tenequm.blackbox.audio")

  // CATap state - set on MainActor in start(), torn down in stop()
  nonisolated(unsafe) private var processTapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
  nonisolated(unsafe) private var aggregateDeviceID: AudioObjectID = AudioObjectID(
    kAudioObjectUnknown)
  nonisolated(unsafe) private var ioProcID: AudioDeviceIOProcID?
  nonisolated(unsafe) private var tapFormat: AVAudioFormat?
  nonisolated(unsafe) private var outputDeviceListenerBlock: AudioObjectPropertyListenerBlock?

  // AVAudioEngine - set on MainActor in start(), torn down in stop()
  nonisolated(unsafe) private var audioEngine: AVAudioEngine?
  nonisolated(unsafe) private var configChangeObserver: (any NSObjectProtocol)?

  // All writer state accessed exclusively on audioQueue
  nonisolated(unsafe) private var writer: AVAssetWriter?
  nonisolated(unsafe) private var systemAudioInput: AVAssetWriterInput?
  nonisolated(unsafe) private var micInput: AVAssetWriterInput?
  nonisolated(unsafe) private var sessionStarted = false
  nonisolated(unsafe) private var stopped = false
  nonisolated(unsafe) private var audioFileURL: URL?
  nonisolated(unsafe) private var fileURL: URL?  // recording directory URL
  nonisolated(unsafe) private var activity: NSObjectProtocol?
  nonisolated(unsafe) private var lastLevelTime: UInt64 = 0
  nonisolated(unsafe) private var pendingMaxLevel: Float = 0
  nonisolated(unsafe) private var writerFailureReported = false
  nonisolated(unsafe) private var diskSpaceTimer: DispatchSourceTimer?
  nonisolated(unsafe) private var lowDiskSpaceWarned = false
  nonisolated(unsafe) private var micTapFormat: AVAudioFormat?
  nonisolated(unsafe) private var micBuffersReceived: Int = 0
  nonisolated(unsafe) private var micBuffersAppended: Int = 0
  nonisolated(unsafe) private var micBuffersDroppedPreSession: Int = 0
  nonisolated(unsafe) private var micBuffersDroppedNotReady: Int = 0
  nonisolated(unsafe) private var micBuffersConversionFailed: Int = 0
  nonisolated(unsafe) private var micBuffersAppendFailed: Int = 0
  nonisolated(unsafe) private var micPeakLevel: Float = 0
  nonisolated(unsafe) private var configChangeGeneration: Int = 0

  // System audio stats
  nonisolated(unsafe) private var systemBuffersReceived: Int = 0
  nonisolated(unsafe) private var systemBuffersAppended: Int = 0
  nonisolated(unsafe) private var systemBuffersDroppedNotReady: Int = 0
  nonisolated(unsafe) private var systemBuffersAppendFailed: Int = 0
  nonisolated(unsafe) private var systemPeakLevel: Float = 0

  // Gap filling state - per pipeline (D8: silence gap filling)
  nonisolated(unsafe) private var systemNextExpected: CMTime = .invalid
  nonisolated(unsafe) private var systemGapsFilled: Int = 0
  nonisolated(unsafe) private var micNextExpected: CMTime = .invalid
  nonisolated(unsafe) private var micGapsFilled: Int = 0

  // D9: device latency offset for mic-system alignment
  nonisolated(unsafe) private var micLatencyOffset: Double = 0

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

    // 1. Get own PID's AudioObjectID
    let myPID = ProcessInfo.processInfo.processIdentifier
    let myObjectID = try Self.translatePID(myPID)

    // 2. Create CATapDescription excluding own PID (global stereo tap)
    let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [myObjectID])
    tapDescription.uuid = UUID()

    // 3. Create process tap
    var tapID = AudioObjectID(kAudioObjectUnknown)
    var err = AudioHardwareCreateProcessTap(tapDescription, &tapID)
    guard err == noErr else {
      if err == OSStatus(kAudioHardwareBadObjectError) {
        throw RecorderError.permissionDenied
      }
      throw RecorderError.tapCreationFailed(
        "AudioHardwareCreateProcessTap failed: \(err)")
    }
    self.processTapID = tapID
    Log.info(Log.recorder, "recorder", "created process tap #\(tapID)")

    // 4. Read tap stream format
    var streamDesc = try Self.readTapFormat(tapID)
    guard let format = AVAudioFormat(streamDescription: &streamDesc) else {
      destroyTap()
      throw RecorderError.tapCreationFailed("invalid tap stream format")
    }
    self.tapFormat = format
    Log.info(
      Log.recorder, "recorder",
      "tap format: \(format.channelCount)ch, \(format.sampleRate)Hz, interleaved=\(format.isInterleaved)"
    )

    // 5. Read system default output device UID
    let outputDeviceID = try Self.readDefaultOutputDevice()
    let outputUID = try Self.readDeviceUID(outputDeviceID)

    // 6. Create aggregate device with tap
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
    err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateDeviceID)
    guard err == noErr else {
      destroyTap()
      throw RecorderError.tapCreationFailed("AudioHardwareCreateAggregateDevice failed: \(err)")
    }
    Log.info(Log.recorder, "recorder", "created aggregate device #\(aggregateDeviceID)")

    do {
      // 7. Setup writer (2-track)
      try setupWriter()

      // 8. Create IO proc on aggregate device
      let capturedFormat = format
      err = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateDeviceID, nil) {
        [weak self] _, inInputData, inInputTime, _, _ in
        guard let self, !self.stopped else { return }
        guard
          let buffer = AVAudioPCMBuffer(
            pcmFormat: capturedFormat, bufferListNoCopy: inInputData, deallocator: nil)
        else { return }
        let hostTime = inInputTime.pointee.mHostTime
        let audioTime = AVAudioTime(hostTime: hostTime)
        // Copy buffer data - IO proc buffer is only valid during callback
        guard
          let copy = AVAudioPCMBuffer(
            pcmFormat: capturedFormat, frameCapacity: buffer.frameLength)
        else { return }
        copy.frameLength = buffer.frameLength
        if capturedFormat.isInterleaved {
          let byteCount =
            Int(buffer.frameLength) * Int(capturedFormat.channelCount)
            * MemoryLayout<Float>.size
          memcpy(copy.floatChannelData![0], buffer.floatChannelData![0], byteCount)
        } else {
          for ch in 0..<Int(capturedFormat.channelCount) {
            let byteCount = Int(buffer.frameLength) * MemoryLayout<Float>.size
            memcpy(copy.floatChannelData![ch], buffer.floatChannelData![ch], byteCount)
          }
        }
        self.audioQueue.async { [weak self] in
          guard let self else { return }
          guard let sampleBuffer = copy.asSampleBuffer(timestamp: audioTime) else { return }
          self.handleSystemSample(sampleBuffer)
        }
      }
      guard err == noErr else {
        throw RecorderError.tapCreationFailed("AudioDeviceCreateIOProcIDWithBlock failed: \(err)")
      }

      // 9. Start IO proc
      activity = ProcessInfo.processInfo.beginActivity(
        options: .userInitiated,
        reason: "Recording call audio"
      )
      err = AudioDeviceStart(aggregateDeviceID, ioProcID)
      guard err == noErr else {
        throw RecorderError.tapCreationFailed("AudioDeviceStart failed: \(err)")
      }
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
      audioQueue.sync {
        writer?.cancelWriting()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        writer = nil
        systemAudioInput = nil
        micInput = nil
        audioFileURL = nil
        fileURL = nil
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
    removeOutputDeviceListener()
    destroyIOProc()
    destroyAggregateDevice()
    destroyTap()

    // Capture engine ref, clear property on MainActor
    let capturedEngine = audioEngine
    audioEngine = nil

    var capturedWriter: AVAssetWriter?
    var capturedFileURL: URL?
    var wasStarted = false
    audioQueue.sync {
      // Set stopped first - blocks any enqueued config change handlers
      stopped = true

      // Mic teardown on audioQueue (serialized with config change handlers)
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
      wasStarted = sessionStarted
      capturedWriter = writer
      capturedFileURL = fileURL
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
    }

    var savedURL: URL?
    if let capturedWriter {
      if !wasStarted {
        capturedWriter.cancelWriting()
        if let capturedFileURL { try? FileManager.default.removeItem(at: capturedFileURL) }
      } else {
        let timeoutTask = Task {
          try await Task.sleep(for: .seconds(5))
          Log.error(Log.recorder, "recorder", "finishWriting timed out after 5s, cancelling")
          capturedWriter.cancelWriting()
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
    if let ioProcID {
      AudioDeviceStop(aggregateDeviceID, ioProcID)
      AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
      self.ioProcID = nil
    }
  }

  private func destroyAggregateDevice() {
    if aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) {
      AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
      aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    }
  }

  private func destroyTap() {
    if processTapID != AudioObjectID(kAudioObjectUnknown) {
      AudioHardwareDestroyProcessTap(processTapID)
      processTapID = AudioObjectID(kAudioObjectUnknown)
    }
  }

  // MARK: - Output Device Change Listener

  private func installOutputDeviceListener() {
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      guard let self, !self.stopped else { return }
      self.audioQueue.async { [weak self] in
        self?.handleOutputDeviceChange()
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

  /// Rebuilds aggregate device and IO proc when system output device changes.
  /// Gap during rebuild is handled by D8 silence gap filling.
  nonisolated private func handleOutputDeviceChange() {
    guard !stopped else { return }
    Log.info(Log.recorder, "recorder", "output device changed, rebuilding aggregate device")

    // Tear down IO proc and aggregate (keep process tap)
    if let ioProcID {
      AudioDeviceStop(aggregateDeviceID, ioProcID)
      AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
      self.ioProcID = nil
    }
    if aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) {
      AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
      aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    }

    // Rebuild with new output device
    guard let outputDeviceID = try? Self.readDefaultOutputDevice(),
      let outputUID = try? Self.readDeviceUID(outputDeviceID)
    else {
      Log.error(Log.recorder, "recorder", "failed to read new output device after change")
      onFailure?(.systemStopped)
      return
    }

    let aggregateUID = UUID().uuidString

    // Destroy old tap and create fresh (tap UUID isn't stored, simpler to recreate)
    if processTapID != AudioObjectID(kAudioObjectUnknown) {
      AudioHardwareDestroyProcessTap(processTapID)
      processTapID = AudioObjectID(kAudioObjectUnknown)
    }

    let myPID = ProcessInfo.processInfo.processIdentifier
    guard let myObjectID = try? Self.translatePID(myPID) else {
      Log.error(Log.recorder, "recorder", "PID translation failed during device change")
      onFailure?(.systemStopped)
      return
    }

    let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [myObjectID])
    tapDescription.uuid = UUID()

    var tapID = AudioObjectID(kAudioObjectUnknown)
    var err = AudioHardwareCreateProcessTap(tapDescription, &tapID)
    guard err == noErr else {
      Log.error(
        Log.recorder, "recorder", "process tap recreation failed during device change: \(err)")
      onFailure?(.systemStopped)
      return
    }
    self.processTapID = tapID

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
    err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateDeviceID)
    guard err == noErr else {
      Log.error(
        Log.recorder, "recorder",
        "aggregate device recreation failed during device change: \(err)")
      AudioHardwareDestroyProcessTap(processTapID)
      processTapID = AudioObjectID(kAudioObjectUnknown)
      onFailure?(.systemStopped)
      return
    }

    guard let capturedFormat = tapFormat else {
      Log.error(Log.recorder, "recorder", "no cached tap format for device change rebuild")
      onFailure?(.systemStopped)
      return
    }

    err = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateDeviceID, nil) {
      [weak self] _, inInputData, inInputTime, _, _ in
      guard let self, !self.stopped else { return }
      guard
        let buffer = AVAudioPCMBuffer(
          pcmFormat: capturedFormat, bufferListNoCopy: inInputData, deallocator: nil)
      else { return }
      let hostTime = inInputTime.pointee.mHostTime
      let audioTime = AVAudioTime(hostTime: hostTime)
      guard
        let copy = AVAudioPCMBuffer(
          pcmFormat: capturedFormat, frameCapacity: buffer.frameLength)
      else { return }
      copy.frameLength = buffer.frameLength
      if capturedFormat.isInterleaved {
        let byteCount =
          Int(buffer.frameLength) * Int(capturedFormat.channelCount)
          * MemoryLayout<Float>.size
        memcpy(copy.floatChannelData![0], buffer.floatChannelData![0], byteCount)
      } else {
        for ch in 0..<Int(capturedFormat.channelCount) {
          let byteCount = Int(buffer.frameLength) * MemoryLayout<Float>.size
          memcpy(copy.floatChannelData![ch], buffer.floatChannelData![ch], byteCount)
        }
      }
      self.audioQueue.async { [weak self] in
        guard let self else { return }
        guard let sampleBuffer = copy.asSampleBuffer(timestamp: audioTime) else { return }
        self.handleSystemSample(sampleBuffer)
      }
    }
    guard err == noErr else {
      Log.error(
        Log.recorder, "recorder", "IO proc recreation failed during device change: \(err)")
      onFailure?(.systemStopped)
      return
    }

    err = AudioDeviceStart(aggregateDeviceID, ioProcID)
    guard err == noErr else {
      Log.error(
        Log.recorder, "recorder", "AudioDeviceStart failed during device change: \(err)")
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
        self?.handleMicBuffer(buffer, at: when)
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
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      self.debounceConfigChange(engine: capturedEngine)
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

  /// Handles mic audio buffer on audioQueue. Drops samples until system audio session starts.
  nonisolated private func handleMicBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
    micBuffersReceived += 1
    guard !stopped else { return }
    guard sessionStarted else {
      micBuffersDroppedPreSession += 1
      return
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
      let offsetTicks = UInt64(micLatencyOffset * Double(NSEC_PER_SEC))
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
  nonisolated private func debounceConfigChange(engine: AVAudioEngine) {
    audioQueue.async { [weak self] in
      guard let self else { return }
      self.configChangeGeneration += 1
      let gen = self.configChangeGeneration
      self.audioQueue.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
        guard let self, !self.stopped, self.configChangeGeneration == gen else { return }
        self.handleEngineConfigChange(engine: engine)
      }
    }
  }

  /// Handles AVAudioEngine configuration change (device plugged/unplugged).
  /// Runs on audioQueue to serialize with stopped flag and buffer handling.
  /// Reinstalls tap and restarts engine. System audio continues regardless.
  nonisolated private func handleEngineConfigChange(engine: AVAudioEngine) {
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
        self?.handleMicBuffer(buffer, at: when)
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
  nonisolated private func queryMicLatencyOffset(deviceID: AudioDeviceID) {
    let inputScope = kAudioObjectPropertyScopeInput
    var latency: UInt32 = 0
    var streamLatency: UInt32 = 0
    var safetyOffset: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)

    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyLatency, mScope: inputScope,
      mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &latency)

    addr.mSelector = kAudioDevicePropertySafetyOffset
    AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &safetyOffset)

    // Stream latency requires reading from the first input stream
    var streamAddr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreams, mScope: inputScope,
      mElement: kAudioObjectPropertyElementMain)
    var streamSize: UInt32 = 0
    if AudioObjectGetPropertyDataSize(deviceID, &streamAddr, 0, nil, &streamSize) == noErr,
      streamSize >= UInt32(MemoryLayout<AudioStreamID>.size)
    {
      var streamID = AudioStreamID(0)
      var readSize = UInt32(MemoryLayout<AudioStreamID>.size)
      if AudioObjectGetPropertyData(deviceID, &streamAddr, 0, nil, &readSize, &streamID) == noErr {
        var sAddr = AudioObjectPropertyAddress(
          mSelector: kAudioStreamPropertyLatency,
          mScope: kAudioObjectPropertyScopeGlobal,
          mElement: kAudioObjectPropertyElementMain)
        var sSize = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(streamID, &sAddr, 0, nil, &sSize, &streamLatency)
      }
    }

    let totalFrames = latency + streamLatency + safetyOffset
    micLatencyOffset = Double(totalFrames) / 48000.0
    Log.info(
      Log.recorder, "recorder",
      "mic latency offset: \(totalFrames) frames (\(String(format: "%.1f", micLatencyOffset * 1000))ms) [device=\(latency) stream=\(streamLatency) safety=\(safetyOffset)]"
    )
  }

  // MARK: - Disk Space Monitoring

  private func startDiskSpaceMonitor() {
    let timer = DispatchSource.makeTimerSource(queue: audioQueue)
    timer.schedule(deadline: .now() + 30, repeating: 30)
    let handler: @Sendable () -> Void = { [weak self] in
      self?.checkDiskSpace()
    }
    timer.setEventHandler(handler: handler)
    timer.resume()
    diskSpaceTimer = timer
  }

  nonisolated private func checkDiskSpace() {
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

    audioQueue.sync {
      self.writer = newWriter
      self.systemAudioInput = systemInput
      self.micInput = newMicInput
      self.audioFileURL = audioURL
      self.fileURL = dirURL
      self.sessionStarted = false
      self.stopped = false
      self.writerFailureReported = false
      self.micBuffersReceived = 0
      self.micBuffersAppended = 0
      self.micBuffersDroppedPreSession = 0
      self.micBuffersDroppedNotReady = 0
      self.micBuffersConversionFailed = 0
      self.micBuffersAppendFailed = 0
      self.micPeakLevel = 0
      self.configChangeGeneration = 0
      self.systemBuffersReceived = 0
      self.systemBuffersAppended = 0
      self.systemBuffersDroppedNotReady = 0
      self.systemBuffersAppendFailed = 0
      self.systemPeakLevel = 0
      self.systemNextExpected = .invalid
      self.systemGapsFilled = 0
      self.micNextExpected = .invalid
      self.micGapsFilled = 0
    }
  }

  /// Resolve CoreAudio device ID to its human-readable name.
  nonisolated private static func audioDeviceName(for deviceID: AudioDeviceID) -> String? {
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceNameCFString,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    let buf = UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: 1)
    defer { buf.deallocate() }
    buf.initialize(to: nil)
    var size = UInt32(MemoryLayout<UnsafeRawPointer?>.size)
    guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, buf) == noErr,
      let raw = buf.pointee
    else { return nil }
    return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
  }

  // MARK: - CoreAudio Property Helpers

  nonisolated private static func translatePID(_ pid: pid_t) throws -> AudioObjectID {
    var pidValue = pid
    var objectID = AudioObjectID(kAudioObjectUnknown)
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var objectSize = UInt32(MemoryLayout<AudioObjectID>.size)
    let err = withUnsafeMutablePointer(to: &pidValue) { pidPtr in
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr,
        UInt32(MemoryLayout<pid_t>.size), pidPtr,
        &objectSize, &objectID)
    }
    guard err == noErr, objectID != AudioObjectID(kAudioObjectUnknown) else {
      throw RecorderError.tapCreationFailed("PID translation failed: \(err)")
    }
    return objectID
  }

  nonisolated private static func readDefaultOutputDevice() throws -> AudioDeviceID {
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var deviceID = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let err = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
    guard err == noErr else {
      throw RecorderError.tapCreationFailed("failed to read default output device: \(err)")
    }
    return deviceID
  }

  nonisolated private static func readDeviceUID(_ deviceID: AudioDeviceID) throws -> String {
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceUID,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    let buf = UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: 1)
    defer { buf.deallocate() }
    buf.initialize(to: nil)
    var size = UInt32(MemoryLayout<UnsafeRawPointer?>.size)
    let err = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, buf)
    guard err == noErr, let raw = buf.pointee else {
      throw RecorderError.tapCreationFailed("failed to read device UID: \(err)")
    }
    return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
  }

  nonisolated private static func readTapFormat(_ tapID: AudioObjectID) throws
    -> AudioStreamBasicDescription
  {
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioTapPropertyFormat,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var asbd = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let err = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
    guard err == noErr else {
      throw RecorderError.tapCreationFailed("failed to read tap format: \(err)")
    }
    return asbd
  }
}

// MARK: - System Audio Handling

extension AudioRecorder {
  nonisolated private func handleSystemSample(_ sampleBuffer: CMSampleBuffer) {
    systemBuffersReceived += 1

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
  nonisolated private func publishAudioLevel(
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
  nonisolated private func fillGap(
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
