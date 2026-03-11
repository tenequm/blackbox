@preconcurrency import AVFoundation
import ScreenCaptureKit

/// Records system audio via ScreenCaptureKit and mic via AVAudioEngine as independent pipelines.
///
/// Dual-track capture: system audio (SCStream) and mic (AVAudioEngine) written as separate
/// AVAssetWriterInputs to a single M4A file. No post-processing or mixing.
/// All mutable recording state is accessed exclusively from `audioQueue` (a serial dispatch queue).
/// `stop()` dispatches teardown onto `audioQueue` to serialize with callbacks, then awaits the writer.
///
/// AVAudioEngine handles device following automatically - on hardware change, the
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

  // Stream - set/cleared on MainActor (before start / after stopCapture)
  nonisolated(unsafe) private var stream: SCStream?

  // AVAudioEngine - set on MainActor in start(), torn down in stop()
  nonisolated(unsafe) private var audioEngine: AVAudioEngine?
  nonisolated(unsafe) private var configChangeObserver: (any NSObjectProtocol)?

  // All writer state accessed exclusively on audioQueue
  nonisolated(unsafe) private var writer: AVAssetWriter?
  nonisolated(unsafe) private var audioInput: AVAssetWriterInput?
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
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: false)
    guard let display = content.displays.first else {
      Log.error(Log.recorder, "recorder", "no display found for \(appName)")
      throw RecorderError.noDisplay
    }

    let filter: SCContentFilter
    if let bundleID {
      guard let app = content.applications.first(where: { $0.bundleIdentifier == bundleID }) else {
        Log.error(Log.recorder, "recorder", "app not found: \(bundleID)")
        throw RecorderError.appNotFound
      }
      filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
    } else {
      filter = SCContentFilter(
        display: display, excludingApplications: [], exceptingWindows: [])
    }

    try setupWriter()

    let config = makeStreamConfig()
    let stream = SCStream(filter: filter, configuration: config, delegate: self)
    do {
      try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)

      activity = ProcessInfo.processInfo.beginActivity(
        options: .userInitiated,
        reason: "Recording call audio"
      )

      self.stream = stream
      try await stream.startCapture()
      Log.recorder.info("stream started for \(self.appName, privacy: .public)")
      startDiskSpaceMonitor()

      // Start mic capture independently - failure does not stop system audio
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
      Log.error(Log.recorder, "recorder", "stream failed to start for \(appName): \(error)")
      stopMicCapture()
      audioQueue.sync {
        writer?.cancelWriting()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        writer = nil
        audioInput = nil
        micInput = nil
        audioFileURL = nil
        fileURL = nil
      }
      self.stream = nil
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

    // Stop mic first (instant) to prevent new samples during teardown
    stopMicCapture()

    if let stream {
      try? await stream.stopCapture()
    }
    stream = nil

    var capturedWriter: AVAssetWriter?
    var capturedFileURL: URL?
    var wasStarted = false
    audioQueue.sync {
      if micEnabled {
        Log.info(
          Log.recorder, "recorder",
          "mic stats: received=\(micBuffersReceived) appended=\(micBuffersAppended) preSession=\(micBuffersDroppedPreSession) notReady=\(micBuffersDroppedNotReady) convFail=\(micBuffersConversionFailed) appendFail=\(micBuffersAppendFailed)"
        )
      }
      wasStarted = sessionStarted
      capturedWriter = writer
      capturedFileURL = fileURL
      stopped = true
      diskSpaceTimer?.cancel()
      diskSpaceTimer = nil
      lowDiskSpaceWarned = false
      audioInput?.markAsFinished()
      micInput?.markAsFinished()
      audioInput = nil
      micInput = nil
      writer = nil
      sessionStarted = false
      micTapFormat = nil
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

  // MARK: - Stream Configuration

  private func makeStreamConfig() -> SCStreamConfiguration {
    let config = SCStreamConfiguration()
    config.width = 2
    config.height = 2
    config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale.max)
    config.showsCursor = false
    config.capturesAudio = true
    config.sampleRate = 48000
    config.channelCount = 2
    config.excludesCurrentProcessAudio = true
    config.captureMicrophone = false
    return config
  }

  // MARK: - AVAudioEngine Mic Capture

  private func startMicCapture() throws {
    let engine = AVAudioEngine()
    let inputNode = engine.inputNode

    let format = inputNode.inputFormat(forBus: 0)
    micTapFormat = format
    Log.info(
      Log.recorder, "recorder",
      "mic format: \(format.channelCount)ch, \(format.sampleRate)Hz")
    let tapHandler: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = {
      [weak self] buffer, when in
      guard let self else { return }
      self.audioQueue.async { [weak self] in
        self?.handleMicBuffer(buffer, at: when)
      }
    }
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: format, block: tapHandler)

    try engine.start()
    audioEngine = engine

    let capturedEngine = engine
    configChangeObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange,
      object: engine,
      queue: nil
    ) { [weak self] _ in
      guard let self else { return }
      self.audioQueue.async { [weak self] in
        self?.handleEngineConfigChange(engine: capturedEngine)
      }
    }

    Log.info(
      Log.recorder, "recorder",
      "mic capture started via AVAudioEngine (format: \(format))")
  }

  private func stopMicCapture() {
    if let observer = configChangeObserver {
      NotificationCenter.default.removeObserver(observer)
      configChangeObserver = nil
    }
    if let engine = audioEngine {
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
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
    guard let sampleBuffer = buffer.asSampleBuffer(timestamp: time) else {
      micBuffersConversionFailed += 1
      Log.recorder.warning("mic PCM-to-CMSampleBuffer conversion failed")
      return
    }
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
    publishAudioLevel(sampleBuffer)
  }

  /// Handles AVAudioEngine configuration change (device plugged/unplugged).
  /// Runs on audioQueue to serialize with stopped flag and buffer handling.
  /// Reinstalls tap with original format and restarts engine. System audio continues regardless.
  nonisolated private func handleEngineConfigChange(engine: AVAudioEngine) {
    guard !stopped else { return }
    Log.info(Log.recorder, "recorder", "audio engine config changed, restarting mic capture")

    let inputNode = engine.inputNode
    inputNode.removeTap(onBus: 0)

    // Use stored format to prevent format mismatch that would fail the writer
    let format = micTapFormat ?? inputNode.inputFormat(forBus: 0)
    let tapHandler: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = {
      [weak self] buffer, when in
      guard let self else { return }
      self.audioQueue.async { [weak self] in
        self?.handleMicBuffer(buffer, at: when)
      }
    }
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: format, block: tapHandler)

    do {
      try engine.start()
      Log.info(Log.recorder, "recorder", "mic capture restarted after device change")
    } catch {
      Log.error(
        Log.recorder, "recorder",
        "mic restart failed after device change, system audio continues: \(error)")
    }
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

    let metadata = RecordingMetadata(
      title: appName,
      createdAt: now,
      appName: appName,
      speakers: [:]
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

    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: systemAudioSettings)
    input.expectsMediaDataInRealTime = true
    newWriter.add(input)

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
      self.audioInput = input
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
    }
  }
}

// MARK: - SCStreamOutput

extension AudioRecorder: SCStreamOutput {
  nonisolated func stream(
    _ stream: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard !stopped,
      sampleBuffer.isValid,
      CMSampleBufferDataIsReady(sampleBuffer)
    else { return }

    switch type {
    case .screen:
      return

    case .audio:
      if !sessionStarted {
        writer?.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
        sessionStarted = true
      }

      if let input = audioInput, input.isReadyForMoreMediaData {
        if !input.append(sampleBuffer) {
          Log.recorder.warning("audio append failed for \(self.appName, privacy: .public)")
          if !writerFailureReported, let w = writer, w.status == .failed {
            writerFailureReported = true
            let desc = w.error?.localizedDescription ?? "unknown writer error"
            Log.error(Log.recorder, "recorder", "writer entered failed state: \(desc)")
            onFailure?(.other(desc))
          }
        }
      }

      publishAudioLevel(sampleBuffer)

    case .microphone:
      return  // mic handled by AVAudioEngine, not SCStream

    @unknown default:
      return
    }
  }

  /// Compute RMS audio level from a sample buffer and publish via callback.
  /// Both system audio and mic call this. Max level is accumulated between
  /// publishes so neither source drowns out the other. Throttled to ~4Hz.
  nonisolated private func publishAudioLevel(_ sampleBuffer: CMSampleBuffer) {
    guard let onAudioLevel else { return }

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
      sumOfSquares += sample * sample
    }
    let rms = (sumOfSquares / Float(floatCount)).squareRoot()
    if rms > pendingMaxLevel { pendingMaxLevel = rms }

    let now = DispatchTime.now().uptimeNanoseconds
    guard now - lastLevelTime >= 250_000_000 else { return }
    lastLevelTime = now
    let level = pendingMaxLevel
    pendingMaxLevel = 0
    onAudioLevel(level)
  }
}

// MARK: - SCStreamDelegate

extension AudioRecorder: SCStreamDelegate {
  nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
    let code = (error as NSError).code
    let failure: RecorderFailure
    switch code {
    case -3801: failure = .permissionDenied
    case -3802, -3821: failure = .systemStopped
    default: failure = .other(error.localizedDescription)
    }
    Log.error(
      Log.recorder, "recorder",
      "stream stopped for \(appName) (code=\(code)): \(error.localizedDescription)")
    onFailure?(failure)
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

    guard
      CMSampleBufferSetDataBufferFromAudioBufferList(
        sampleBuffer!,
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
  case appNotFound
  case writerFailed

  var errorDescription: String? {
    switch self {
    case .noDisplay: "No display found"
    case .appNotFound: "Target application not found"
    case .writerFailed: "Failed to start audio writer"
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
