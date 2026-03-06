import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Records audio from a specific app via ScreenCaptureKit.
///
/// Lifecycle is controlled externally (by AudioMonitor). This class captures and writes.
/// All mutable recording state is accessed exclusively from `audioQueue` (a serial dispatch queue).
/// `stop()` dispatches teardown onto `audioQueue` to serialize with callbacks, then awaits the writer.
final class AudioRecorder: NSObject, @unchecked Sendable {
  nonisolated let bundleID: String
  nonisolated let appName: String
  nonisolated let micEnabled: Bool
  nonisolated let saveDirectory: URL

  nonisolated(unsafe) var onError: (@Sendable (any Error) -> Void)?

  private let audioQueue = DispatchQueue(label: "com.tenequm.blackbox.audio")

  // Stream - set/cleared on MainActor (before start / after stopCapture)
  nonisolated(unsafe) private var stream: SCStream?

  // All writer state accessed exclusively from audioQueue
  nonisolated(unsafe) private var writer: AVAssetWriter?
  nonisolated(unsafe) private var systemAudioInput: AVAssetWriterInput?
  nonisolated(unsafe) private var micAudioInput: AVAssetWriterInput?
  nonisolated(unsafe) private var sessionStarted = false
  nonisolated(unsafe) private var stopped = false
  nonisolated(unsafe) private var fileURL: URL?
  nonisolated(unsafe) private var activity: NSObjectProtocol?

  init(bundleID: String, appName: String, micEnabled: Bool, saveDirectory: URL) {
    self.bundleID = bundleID
    self.appName = appName
    self.micEnabled = micEnabled
    self.saveDirectory = saveDirectory
  }

  /// Starts capturing audio and writing to file immediately.
  func start() async throws {
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: false)
    guard let display = content.displays.first else {
      throw RecorderError.noDisplay
    }
    guard let app = content.applications.first(where: { $0.bundleIdentifier == bundleID }) else {
      throw RecorderError.appNotFound
    }

    // Set up file writer before starting stream
    try setupWriter()

    let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])

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
    }

    let stream = SCStream(filter: filter, configuration: config, delegate: self)
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

    do {
      try await stream.startCapture()
    } catch {
      // Clean up writer and activity if stream fails to start
      writer?.cancelWriting()
      if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
      writer = nil
      systemAudioInput = nil
      micAudioInput = nil
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
    if let stream {
      try? await stream.stopCapture()
    }
    stream = nil

    // Mark stopped and finalize writer on audioQueue to serialize with any in-flight callbacks
    audioQueue.sync {
      stopped = true
      systemAudioInput?.markAsFinished()
      micAudioInput?.markAsFinished()
    }

    // finishWriting is async and safe to call from MainActor after markAsFinished
    var savedURL: URL?
    if let writer {
      if !sessionStarted {
        // No audio was ever received - cancel and delete empty file
        writer.cancelWriting()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
      } else {
        await writer.finishWriting()
        if writer.status == .failed {
          print("Blackbox: writer failed: \(writer.error?.localizedDescription ?? "unknown")")
          if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        } else {
          savedURL = fileURL
        }
      }
    }

    writer = nil
    systemAudioInput = nil
    micAudioInput = nil
    sessionStarted = false
    fileURL = nil

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
    fileURL = url

    let audioSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 48000.0,
      AVNumberOfChannelsKey: 2,
      AVEncoderBitRateKey: 128_000,
    ]

    let writer = try AVAssetWriter(url: url, fileType: .m4a)

    let systemInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
    systemInput.expectsMediaDataInRealTime = true
    writer.add(systemInput)
    systemAudioInput = systemInput

    if micEnabled {
      let micInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
      micInput.expectsMediaDataInRealTime = true
      writer.add(micInput)
      micAudioInput = micInput
    }

    guard writer.startWriting() else {
      let err = writer.error
      throw err ?? RecorderError.writerFailed
    }
    self.writer = writer
    stopped = false
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
      }
      if let input = systemAudioInput, input.isReadyForMoreMediaData {
        input.append(sampleBuffer)
      }
    case .microphone:
      if !sessionStarted {
        writer?.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
        sessionStarted = true
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
