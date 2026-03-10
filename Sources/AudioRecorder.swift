import AVFoundation
import CoreAudio
import CoreMedia
import ScreenCaptureKit

/// Records audio from a specific app via ScreenCaptureKit.
///
/// Dual-track capture: system audio and mic written as separate AVAssetWriterInputs,
/// then auto-mixed to single-track M4A on save via AVMutableComposition.
/// All mutable recording state is accessed exclusively from `audioQueue` (a serial dispatch queue).
/// `stop()` dispatches teardown onto `audioQueue` to serialize with callbacks, then awaits the writer.
///
/// Self-healing behavior:
/// - Monitors default audio input device changes via CoreAudio property listener
/// - On device change: attempts seamless `updateConfiguration()` on the running stream
/// - On failure: reports categorized `RecorderFailure` to owner for policy-level recovery
/// - `movieFragmentInterval` ensures partial file recovery on crash
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

  // All writer state accessed exclusively on audioQueue
  nonisolated(unsafe) private var writer: AVAssetWriter?
  nonisolated(unsafe) private var audioInput: AVAssetWriterInput?
  nonisolated(unsafe) private var micInput: AVAssetWriterInput?
  nonisolated(unsafe) private var sessionStarted = false
  nonisolated(unsafe) private var stopped = false
  nonisolated(unsafe) private var audioFileURL: URL?
  nonisolated(unsafe) private var fileURL: URL?  // recording directory URL
  nonisolated(unsafe) private var activity: NSObjectProtocol?
  nonisolated(unsafe) private var deviceListenerRegistered = false
  nonisolated(unsafe) private var lastLevelTime: UInt64 = 0
  nonisolated(unsafe) private var writerFailureReported = false
  nonisolated(unsafe) private var diskSpaceTimer: DispatchSourceTimer?
  nonisolated(unsafe) private var lowDiskSpaceWarned = false

  init(
    bundleID: String? = nil, appName: String, micEnabled: Bool, saveDirectory: URL,
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
    if deviceListenerRegistered {
      let selfPtr = Unmanaged.passUnretained(self).toOpaque()
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )
      AudioObjectRemovePropertyListener(
        AudioObjectID(kAudioObjectSystemObject), &address, Self.deviceChangeListenerProc, selfPtr)
    }
    if let activity { ProcessInfo.processInfo.endActivity(activity) }
  }

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
      // Display-wide capture: exclude virtual audio processors (Krisp, etc.)
      // whose processed mic output would duplicate the user's voice.
      let virtualAudioPrefixes = [
        "ai.krisp",
        "com.rogueamoeba.SoundSource",
        "com.rogueamoeba.loopback",
      ]
      let excluded = content.applications.filter { app in
        let bid = app.bundleIdentifier
        return virtualAudioPrefixes.contains { bid.hasPrefix($0) }
      }
      if !excluded.isEmpty {
        let names = excluded.map(\.bundleIdentifier).joined(separator: ", ")
        Log.info(Log.recorder, "recorder", "excluding virtual audio apps from capture: \(names)")
      }
      filter = SCContentFilter(
        display: display, excludingApplications: excluded, exceptingWindows: [])
    }

    try setupWriter()

    let config = makeStreamConfig()
    let stream = SCStream(filter: filter, configuration: config, delegate: self)
    do {
      try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
      if micEnabled {
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: audioQueue)
      }

      activity = ProcessInfo.processInfo.beginActivity(
        options: .userInitiatedAllowingIdleSystemSleep,
        reason: "Recording call audio"
      )

      self.stream = stream
      try await stream.startCapture()
      Log.recorder.info("stream started for \(self.appName, privacy: .public)")
      addDeviceListener()
      startDiskSpaceMonitor()
    } catch {
      Log.error(Log.recorder, "recorder", "stream failed to start for \(appName): \(error)")
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
    removeDeviceListener()
    if let stream {
      try? await stream.stopCapture()
    }
    stream = nil

    var capturedWriter: AVAssetWriter?
    var capturedFileURL: URL?
    var capturedAudioFileURL: URL?
    var capturedMicEnabled = false
    var wasStarted = false
    audioQueue.sync {
      wasStarted = sessionStarted
      capturedWriter = writer
      capturedFileURL = fileURL
      capturedAudioFileURL = audioFileURL
      capturedMicEnabled = micInput != nil
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
        }
        if capturedWriter.status == .completed {
          // Mix dual-track to single-track if mic was enabled
          if capturedMicEnabled, let audioFile = capturedAudioFileURL {
            do {
              try await Self.mixToSingleTrack(audioFile)
            } catch {
              Log.error(
                Log.recorder, "recorder",
                "mix failed, keeping dual-track: \(error.localizedDescription)")
            }
          }
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

  private func makeStreamConfig(micDeviceID: String? = nil) -> SCStreamConfiguration {
    let config = SCStreamConfiguration()
    config.width = 2
    config.height = 2
    config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale.max)
    config.showsCursor = false
    config.capturesAudio = true
    config.sampleRate = 48000
    config.channelCount = 2
    config.excludesCurrentProcessAudio = true
    if micEnabled {
      config.captureMicrophone = true
      config.microphoneCaptureDeviceID =
        micDeviceID ?? AVCaptureDevice.default(for: .audio)?.uniqueID
    }
    return config
  }

  // MARK: - Device Change Monitoring

  func handleDefaultDeviceChange() {
    guard micEnabled, let stream else { return }
    guard let newDeviceID = AVCaptureDevice.default(for: .audio)?.uniqueID else {
      Log.error(Log.recorder, "recorder", "no default audio device available after change")
      return
    }

    let config = makeStreamConfig(micDeviceID: newDeviceID)
    Task {
      do {
        try await stream.updateConfiguration(config)
        Log.recorder.info("mic seamlessly switched to \(newDeviceID, privacy: .public)")
      } catch {
        Log.error(Log.recorder, "recorder", "updateConfiguration failed: \(error)")
        onFailure?(.deviceChangeFailed)
      }
    }
  }

  private func startDiskSpaceMonitor() {
    let timer = DispatchSource.makeTimerSource(queue: audioQueue)
    timer.schedule(deadline: .now() + 30, repeating: 30)
    timer.setEventHandler { [weak self] in
      self?.checkDiskSpace()
    }
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

  private func addDeviceListener() {
    guard micEnabled, !deviceListenerRegistered else { return }
    let selfPtr = Unmanaged.passUnretained(self).toOpaque()
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectAddPropertyListener(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      Self.deviceChangeListenerProc,
      selfPtr
    )
    if status == noErr {
      deviceListenerRegistered = true
    } else {
      Log.error(Log.recorder, "recorder", "failed to register device listener: \(status)")
    }
  }

  private func removeDeviceListener() {
    guard deviceListenerRegistered else { return }
    let selfPtr = Unmanaged.passUnretained(self).toOpaque()
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectRemovePropertyListener(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      Self.deviceChangeListenerProc,
      selfPtr
    )
    deviceListenerRegistered = false
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

    let audioSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 48000.0,
      AVNumberOfChannelsKey: 2,
      AVEncoderBitRateKey: 128_000,
    ]

    let newWriter = try AVAssetWriter(url: audioURL, fileType: .m4a)
    newWriter.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)

    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
    input.expectsMediaDataInRealTime = true
    newWriter.add(input)

    var newMicInput: AVAssetWriterInput?
    if micEnabled {
      let mi = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
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
    }
  }
}

// MARK: - CoreAudio Device Change Callback

extension AudioRecorder {
  nonisolated static let deviceChangeListenerProc: AudioObjectPropertyListenerProc = {
    _, _, _, clientData in
    guard let clientData else { return noErr }
    let recorder = Unmanaged<AudioRecorder>.fromOpaque(clientData).takeUnretainedValue()
    Task { @MainActor in
      recorder.handleDefaultDeviceChange()
    }
    return noErr
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
      guard sessionStarted else { return }
      if let input = micInput, input.isReadyForMoreMediaData {
        if !input.append(sampleBuffer) {
          Log.recorder.warning("mic append failed for \(self.appName, privacy: .public)")
        }
      }

    @unknown default:
      return
    }
  }

  /// Compute RMS audio level from a sample buffer and publish via callback.
  /// Throttled to ~4Hz to avoid flooding the UI.
  nonisolated private func publishAudioLevel(_ sampleBuffer: CMSampleBuffer) {
    guard let onAudioLevel else { return }
    let now = DispatchTime.now().uptimeNanoseconds
    guard now - lastLevelTime >= 250_000_000 else { return }
    lastLevelTime = now

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
    onAudioLevel(rms)
  }
}

// MARK: - Post-Recording Mix

extension AudioRecorder {
  /// Mixes a dual-track M4A (system audio + mic) into a single-track file,
  /// atomically replacing the original.
  private static func mixToSingleTrack(_ fileURL: URL) async throws {
    let asset = AVURLAsset(url: fileURL)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    guard tracks.count >= 2 else { return }

    let composition = AVMutableComposition()
    let duration = try await asset.load(.duration)

    for sourceTrack in tracks {
      guard
        let compositionTrack = composition.addMutableTrack(
          withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
      else { continue }
      try compositionTrack.insertTimeRange(
        CMTimeRange(start: .zero, duration: duration),
        of: sourceTrack, at: .zero)
    }

    let tempURL = fileURL.deletingLastPathComponent()
      .appendingPathComponent("audio-mixed.m4a")

    guard
      let exporter = AVAssetExportSession(
        asset: composition, presetName: AVAssetExportPresetAppleM4A)
    else {
      throw RecorderError.mixFailed
    }

    try await exporter.export(to: tempURL, as: .m4a)
    _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
    Log.info(Log.recorder, "recorder", "mixed \(tracks.count) tracks into single file")
  }
}

// MARK: - SCStreamDelegate

extension AudioRecorder: SCStreamDelegate {
  nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
    let code = (error as NSError).code
    let failure: RecorderFailure
    switch code {
    case -3801: failure = .permissionDenied
    case -3802: failure = .systemStopped
    case -3820: failure = .micFailed
    case -3821: failure = .systemStopped
    default: failure = .other(error.localizedDescription)
    }
    Log.error(
      Log.recorder, "recorder",
      "stream stopped for \(appName) (code=\(code)): \(error.localizedDescription)")
    onFailure?(failure)
  }
}

// MARK: - Error Types

enum RecorderError: Error, LocalizedError {
  case noDisplay
  case appNotFound
  case writerFailed
  case mixFailed

  var errorDescription: String? {
    switch self {
    case .noDisplay: "No display found"
    case .appNotFound: "Target application not found"
    case .writerFailed: "Failed to start audio writer"
    case .mixFailed: "Failed to mix audio tracks"
    }
  }
}

/// Categorized runtime failures reported by AudioRecorder.
/// AudioMonitor uses these to decide recovery strategy.
enum RecorderFailure: Sendable {
  case micFailed
  case systemStopped
  case permissionDenied
  case deviceChangeFailed
  case lowDiskSpace
  case other(String)
}
