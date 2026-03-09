import AVFoundation
import CoreAudio
import CoreMedia
import ScreenCaptureKit

/// Records audio from a specific app via ScreenCaptureKit.
///
/// Lifecycle is controlled externally (by AudioMonitor). This class captures and writes.
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

  private let audioQueue = DispatchQueue(label: "com.tenequm.blackbox.audio")

  // Stream - set/cleared on MainActor (before start / after stopCapture)
  nonisolated(unsafe) private var stream: SCStream?

  // All writer state published to audioQueue via sync in setupWriter/stop
  nonisolated(unsafe) private var writer: AVAssetWriter?
  nonisolated(unsafe) private var systemAudioInput: AVAssetWriterInput?
  nonisolated(unsafe) private var micAudioInput: AVAssetWriterInput?
  nonisolated(unsafe) private var sessionStarted = false
  nonisolated(unsafe) private var stopped = false
  nonisolated(unsafe) private var fileURL: URL?
  nonisolated(unsafe) private var activity: NSObjectProtocol?
  nonisolated(unsafe) private var deviceListenerRegistered = false

  init(
    bundleID: String? = nil, appName: String, micEnabled: Bool, saveDirectory: URL,
    onFailure: (@Sendable (RecorderFailure) -> Void)? = nil
  ) {
    self.bundleID = bundleID
    self.appName = appName
    self.micEnabled = micEnabled
    self.saveDirectory = saveDirectory
    self.onFailure = onFailure
  }

  // Safety net: CoreAudio device listener holds an Unmanaged.passUnretained(self) pointer.
  // stop() handles the normal path; deinit catches leaks if stop() is never called.
  //
  // deinit is nonisolated in Swift 6, so we inline the CoreAudio C call directly
  // rather than calling the MainActor-isolated removeDeviceListener().
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
      // App-specific capture
      guard let app = content.applications.first(where: { $0.bundleIdentifier == bundleID }) else {
        Log.error(Log.recorder, "recorder", "app not found: \(bundleID)")
        throw RecorderError.appNotFound
      }
      filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
    } else {
      // Display-wide capture (all system audio)
      filter = SCContentFilter(
        display: display, excludingApplications: [], exceptingWindows: [])
    }

    // Set up file writer before starting stream
    try setupWriter()

    let config = makeStreamConfig()

    let stream = SCStream(filter: filter, configuration: config, delegate: self)
    do {
      try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: audioQueue)
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
    } catch {
      Log.error(Log.recorder, "recorder", "stream failed to start for \(appName): \(error)")
      // Clean up writer, stream, and activity if any step fails
      audioQueue.sync {
        writer?.cancelWriting()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        writer = nil
        systemAudioInput = nil
        micAudioInput = nil
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
  /// Serializes writer teardown on audioQueue to prevent races with callbacks.
  /// Returns the saved file URL, or nil if no audio was captured or write failed.
  @discardableResult
  func stop() async -> URL? {
    Log.recorder.info("stop() for \(self.appName, privacy: .public)")
    removeDeviceListener()
    if let stream {
      try? await stream.stopCapture()
    }
    stream = nil

    // Capture and nil all writer state inside audioQueue.sync to serialize with callbacks.
    // After this block, no callback can access writer/inputs (they see nil/stopped).
    var capturedWriter: AVAssetWriter?
    var capturedFileURL: URL?
    var wasStarted = false
    audioQueue.sync {
      wasStarted = sessionStarted
      capturedWriter = writer
      capturedFileURL = fileURL
      stopped = true
      systemAudioInput?.markAsFinished()
      micAudioInput?.markAsFinished()
      // Nil out so any in-flight callback that passed the stopped guard sees nil
      systemAudioInput = nil
      micAudioInput = nil
      writer = nil
      sessionStarted = false
      fileURL = nil
    }

    // finishWriting uses captured locals - safe from MainActor after audioQueue.sync.
    // Timeout guards against AVAssetWriter hanging indefinitely (rare but documented).
    // applicationShouldTerminate has its own 5s timeout for quit, but manual "Stop Recording"
    // would hang forever without this.
    var savedURL: URL?
    if let capturedWriter {
      if !wasStarted {
        capturedWriter.cancelWriting()
        if let capturedFileURL { try? FileManager.default.removeItem(at: capturedFileURL) }
      } else {
        // Timeout guard: if finishWriting hangs (rare but documented), cancelWriting
        // terminates it so stop() doesn't block forever. applicationShouldTerminate has
        // its own 5s timeout for quit, but manual "Stop Recording" needs this.
        // We stay on MainActor (no TaskGroup/sending dance) - the timeout Task captures
        // capturedWriter from the same actor context.
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
          // Don't delete - the file may contain recoverable audio up to the last
          // movieFragmentInterval boundary. Preserve it so the user can attempt recovery.
          savedURL = capturedFileURL
        } else {
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

  /// Called on MainActor when CoreAudio reports the default input device changed.
  /// Attempts seamless mic switch via updateConfiguration. Falls back to onFailure
  /// if the update fails, letting AudioMonitor handle stream restart.
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
      Log.recorder.debug("device change listener registered for \(self.appName, privacy: .public)")
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
    Log.recorder.debug("device change listener removed for \(self.appName, privacy: .public)")
  }

  // MARK: - Writer Setup

  private func setupWriter() throws {
    try FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    // Append short UUID suffix to prevent collision when two recordings start
    // within the same second (e.g. auto + manual simultaneously).
    let suffix = UUID().uuidString.prefix(4)
    let filename = "\(formatter.string(from: Date()))_\(appName)_\(suffix).m4a"
    let url = saveDirectory.appendingPathComponent(filename)
    Log.recorder.info("writing to \(url.lastPathComponent, privacy: .public)")

    let audioSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 48000.0,
      AVNumberOfChannelsKey: 2,
      AVEncoderBitRateKey: 128_000,
    ]

    let newWriter = try AVAssetWriter(url: url, fileType: .m4a)
    // Write fragment headers every 10s so the file is recoverable on crash
    newWriter.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)

    let systemInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
    systemInput.expectsMediaDataInRealTime = true
    newWriter.add(systemInput)

    var micInput: AVAssetWriterInput?
    if micEnabled {
      let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
      input.expectsMediaDataInRealTime = true
      newWriter.add(input)
      micInput = input
    }

    guard newWriter.startWriting() else {
      let err = newWriter.error
      Log.error(
        Log.recorder, "recorder",
        "writer startWriting failed: \(err?.localizedDescription ?? "unknown")")
      throw err ?? RecorderError.writerFailed
    }

    // Publish mutable state to audioQueue with memory barrier so callbacks see it
    audioQueue.sync {
      self.writer = newWriter
      self.systemAudioInput = systemInput
      self.micAudioInput = micInput
      self.fileURL = url
      self.sessionStarted = false
      self.stopped = false
    }
  }
}

// MARK: - CoreAudio Device Change Callback

extension AudioRecorder {
  // C function pointer for AudioObjectAddPropertyListener.
  // Stored as a static let so the same pointer is used for both Add and Remove.
  // Uses the non-block variant to avoid the known Swift closure identity bug
  // that prevents correct listener removal with AudioObjectRemovePropertyListenerBlock.
  // Fires on an internal CoreAudio thread; dispatches to MainActor for stream access.
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
      // Start session on first buffer (system or mic, whichever arrives first)
      if !sessionStarted {
        writer?.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
        sessionStarted = true
        Log.recorder.debug("first audio buffer received for \(self.appName, privacy: .public)")
      }
      if let input = systemAudioInput, input.isReadyForMoreMediaData {
        input.append(sampleBuffer)
      }
    case .microphone:
      if !sessionStarted {
        writer?.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
        sessionStarted = true
        Log.recorder.debug("first mic buffer received for \(self.appName, privacy: .public)")
      }
      if let input = micAudioInput, input.isReadyForMoreMediaData {
        input.append(sampleBuffer)
      }
    @unknown default:
      return
    }
  }
}

// MARK: - SCStreamDelegate

extension AudioRecorder: SCStreamDelegate {
  nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
    let code = (error as NSError).code
    let failure: RecorderFailure
    switch code {
    case -3801: failure = .permissionDenied
    case -3802: failure = .systemStopped  // content invalidated (e.g. display disconnected)
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
  /// Microphone capture specifically failed (-3820). Stream is dead.
  /// Recovery: restart without mic to preserve system audio.
  case micFailed
  /// System killed the stream (-3821) due to sleep/wake or resource pressure.
  /// Recovery: save file, restart with new stream.
  case systemStopped
  /// Screen recording permission was revoked. Cannot recover without user action.
  case permissionDenied
  /// updateConfiguration failed to switch mic device.
  /// Recovery: restart stream to pick up new device.
  case deviceChangeFailed
  /// Unexpected error.
  case other(String)
}
