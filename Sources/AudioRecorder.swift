import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Records audio from a specific app via ScreenCaptureKit.
///
/// Lifecycle is controlled externally (by AudioMonitor). This class captures and writes.
/// All mutable recording state is accessed exclusively from `audioQueue` (a serial dispatch queue).
/// `stop()` dispatches teardown onto `audioQueue` to serialize with callbacks, then awaits the writer.
final class AudioRecorder: NSObject, @unchecked Sendable {
  nonisolated let bundleID: String?
  nonisolated let appName: String
  nonisolated let micEnabled: Bool
  nonisolated let saveDirectory: URL

  nonisolated let onError: (@Sendable (any Error) -> Void)?

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

  init(
    bundleID: String? = nil, appName: String, micEnabled: Bool, saveDirectory: URL,
    onError: (@Sendable (any Error) -> Void)? = nil
  ) {
    self.bundleID = bundleID
    self.appName = appName
    self.micEnabled = micEnabled
    self.saveDirectory = saveDirectory
    self.onError = onError
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
      config.microphoneCaptureDeviceID = AVCaptureDevice.default(for: .audio)?.uniqueID
    }

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

    // finishWriting uses captured locals - safe from MainActor after audioQueue.sync
    var savedURL: URL?
    if let capturedWriter {
      if !wasStarted {
        capturedWriter.cancelWriting()
        if let capturedFileURL { try? FileManager.default.removeItem(at: capturedFileURL) }
      } else {
        await capturedWriter.finishWriting()
        if capturedWriter.status == .failed {
          Log.error(
            Log.recorder, "recorder",
            "writer failed: \(capturedWriter.error?.localizedDescription ?? "unknown")")
          if let capturedFileURL { try? FileManager.default.removeItem(at: capturedFileURL) }
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

  // MARK: - Writer Setup

  private func setupWriter() throws {
    try FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    let filename = "\(formatter.string(from: Date()))_\(appName).m4a"
    let url = saveDirectory.appendingPathComponent(filename)
    Log.recorder.info("writing to \(url.lastPathComponent, privacy: .public)")

    let audioSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 48000.0,
      AVNumberOfChannelsKey: 2,
      AVEncoderBitRateKey: 128_000,
    ]

    let newWriter = try AVAssetWriter(url: url, fileType: .m4a)

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
    onError?(error)
  }
}

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
