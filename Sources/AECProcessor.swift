@preconcurrency import AVFoundation
import CoreMedia
import DTLNAecCoreML

/// Post-processes recorded audio to remove echo from the mic track using DTLN-aec.
/// Reads dual-track `audio.m4a`, runs echo cancellation on the mic track using
/// system audio as the far-end reference, writes `audio-processed.m4a` with both
/// tracks at 16kHz mono AAC. Original file is preserved for fallback.
enum AECProcessor {

  /// The decode/inference loop blocks its thread for the whole recording
  /// (`copyNextSampleBuffer` is synchronous). It must run here, not on the
  /// Swift cooperative pool: AVAssetReader delivers samples via libdispatch,
  /// and with every pool thread blocked inside it - e.g. two recordings
  /// finishing together on a 3-core machine, or parallel tests - delivery
  /// never gets a thread and the reads deadlock.
  private static let workQueue = DispatchQueue(
    label: "com.tenequm.blackbox.aec", qos: .utility)

  nonisolated private static let modelBundleName = "DTLNAecCoreML_DTLNAec256.bundle"

  /// Resolves the CoreML model bundle ourselves rather than through
  /// `DTLNAec256.bundle`, which is SwiftPM's generated `Bundle.module`.
  ///
  /// That accessor looks for the bundle at `Bundle.main.bundleURL` - the `.app`
  /// root - and falls back to an absolute path inside the developer's `.build`
  /// directory. The Makefile puts resources in `Contents/Resources`, where they
  /// belong and where codesigning requires them, so the first location never
  /// matched and the second only ever existed on the machine that built it.
  /// On every other Mac, and on this one once the build directory moved, the
  /// accessor hit its `fatalError` - on a background queue, so echo
  /// cancellation crashed the app outright rather than failing.
  ///
  /// Returning nil here turns that into an ordinary thrown error.
  nonisolated private static func modelBundle() -> Bundle? {
    var candidates: [URL] = []
    // The `.app` layout, where codesigning requires resources to live.
    if let resources = Bundle.main.resourceURL {
      candidates.append(resources.appendingPathComponent(modelBundleName))
    }
    candidates.append(Bundle.main.bundleURL.appendingPathComponent(modelBundleName))
    // The bare-executable layout: `swift test` and `swift run` put resource
    // bundles beside the binary rather than inside a wrapper.
    if let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent() {
      candidates.append(executableDirectory.appendingPathComponent(modelBundleName))
    }
    // The xctest layout, where `Bundle.main` is the test runner and the
    // resources belong to the test bundle instead.
    for bundle in Bundle.allBundles {
      if let resources = bundle.resourceURL {
        candidates.append(resources.appendingPathComponent(modelBundleName))
      }
      candidates.append(bundle.bundleURL.appendingPathComponent(modelBundleName))
      // The directory *containing* the bundle: SwiftPM puts resource bundles
      // beside `BlackboxPackageTests.xctest`, not inside it.
      candidates.append(
        bundle.bundleURL.deletingLastPathComponent().appendingPathComponent(modelBundleName))
    }
    for url in candidates {
      guard FileManager.default.fileExists(atPath: url.path) else { continue }
      if let bundle = Bundle(url: url) { return bundle }
    }
    Log.error(
      Log.app, "aec",
      "could not find \(modelBundleName) in \(candidates.map(\.path).joined(separator: ", "))")
    return nil
  }

  /// Directories with a run in flight. Two runs for one recording used to be
  /// reachable by clicking away and back: the button is gated on
  /// `isProcessingAEC`, which is `@State` on a view carrying `.id(recording.id)`,
  /// so reselecting the row rebuilt it as false while the first run - an
  /// unstructured `Task` nothing cancels - was still going. The second run's
  /// scratch cleanup then unlinked the first run's output from under it.
  private static var runningDirectories: Set<String> = []

  /// What a run did, so the caller can say so. All three non-outcomes used to
  /// be a bare `return`, which the button rendered as a spinner that stopped
  /// and nothing else - the same silence the error path was changed to remove.
  enum Outcome {
    case processed
    case alreadyProcessed
    case alreadyRunning
    /// No mic track to clean. Legitimate: the microphone is a user setting.
    case nothingToProcess
  }

  /// Runs echo cancellation over a recording directory, writing
  /// `audio-processed.m4a` beside the original. Does nothing if the recording
  /// is already processed, is single-track, or is already being processed, and
  /// says which. Throws on failure; the original is never modified.
  @discardableResult
  static func process(recordingDirectory: URL) async throws -> Outcome {
    let inputURL = recordingDirectory.appendingPathComponent(RecordingStore.audioName)
    let outputURL = recordingDirectory.appendingPathComponent(
      RecordingStore.processedAudioName)

    // Usable, not merely present: an empty file from a killed run must not
    // read as "already processed" and block a re-run forever.
    guard !RecordingStore.isUsable(outputURL) else { return .alreadyProcessed }

    let key = recordingDirectory.path
    guard !runningDirectories.contains(key) else { return .alreadyRunning }
    runningDirectories.insert(key)
    defer { runningDirectories.remove(key) }

    try? FileManager.default.removeItem(at: outputURL)

    // Written to a scratch name and moved into place only on success. Writing
    // straight to `audio-processed.m4a` meant a quit during a long run - which
    // the user has no reason to think is unsafe - left a headerless file that
    // `RecordingStore.audioURL(in:)` then *prefers*: it silently became the
    // transcription source (and got billed), the export source and the playback
    // source, while `hasProcessed` went true from a successful stat, hiding the
    // button that could have regenerated it.
    //
    // The name carries a UUID so two runs - in this process or in an overlapping
    // second instance, which onboarding's relaunch creates - cannot share one
    // scratch path.
    let scratchURL = recordingDirectory.appendingPathComponent(
      RecordingStore.partialProcessedName())

    do {
      let wroteOutput = try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Bool, Error>) in
        workQueue.async {
          continuation.resume(
            with: Result { try Self.run(inputURL: inputURL, outputURL: scratchURL) })
        }
      }
      // `run` reports whether it produced a file. A single-track recording is a
      // legitimate no-op - the mic is a user setting - and moving a scratch file
      // that was never created threw a filesystem error the user read as "echo
      // cancellation failed".
      guard wroteOutput else {
        Log.info(Log.recorder, "aec", "nothing to process")
        return .nothingToProcess
      }
      try FileManager.default.moveItem(at: scratchURL, to: outputURL)
      Log.info(Log.recorder, "aec", "echo cancellation complete")
      return .processed
    } catch {
      Log.error(Log.recorder, "aec", "failed: \(error.localizedDescription)")
      try? FileManager.default.removeItem(at: scratchURL)
      throw error
    }
  }

  /// Removes scratch files a killed echo-cancellation run left behind.
  nonisolated static func sweepPartialFiles(in saveDirectory: URL) {
    for directory in RecordingStore.directories(in: saveDirectory) {
      let names =
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
      for name in names where RecordingStore.isPartialProcessedName(name) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
      }
    }
  }

  // MARK: - Streaming Pipeline (background thread)

  /// Returns true when it produced a file at `outputURL`, false when there was
  /// nothing to do. The caller only publishes the output when this is true.
  nonisolated private static func run(inputURL: URL, outputURL: URL) throws -> Bool {
    let sampleRate: Double = 16000
    let chunkSize = 1024

    let asset = AVURLAsset(url: inputURL)
    let tracks = try loadAudioTracksBlocking(asset)
    guard tracks.count >= 2 else {
      Log.info(Log.recorder, "aec", "single-track recording, skipping")
      return false
    }

    // Track layout:
    // 2-track (current): [0]=system audio, [1]=mic
    // 3-track (legacy, pre-v0.7.0): [0]=display-wide, [1]=per-app, [2]=mic
    let micTrack = tracks[tracks.count - 1]
    let referenceTrack: AVAssetTrack
    if tracks.count >= 3 {
      referenceTrack = tracks[1]
      Log.info(Log.recorder, "aec", "using per-app track as AEC reference (3-track)")
    } else {
      referenceTrack = tracks[0]
    }

    let pcmSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]

    // Two readers (one per track) for independent interleaved reading
    let sysReader = try AVAssetReader(asset: asset)
    let sysOutput = AVAssetReaderTrackOutput(
      track: referenceTrack, outputSettings: pcmSettings)
    sysOutput.alwaysCopiesSampleData = false
    sysReader.add(sysOutput)

    let micReader = try AVAssetReader(asset: asset)
    let micOutput = AVAssetReaderTrackOutput(track: micTrack, outputSettings: pcmSettings)
    micOutput.alwaysCopiesSampleData = false
    micReader.add(micOutput)

    guard sysReader.startReading() else {
      throw AECError.readFailed(sysReader.error?.localizedDescription ?? "system track")
    }
    guard micReader.startReading() else {
      throw AECError.readFailed(micReader.error?.localizedDescription ?? "mic track")
    }

    // Writer with two AAC inputs
    let aacSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: 1,
      AVEncoderBitRateKey: 48_000,
    ]

    let writer = try AVAssetWriter(url: outputURL, fileType: .m4a)

    let sysInput = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings)
    sysInput.expectsMediaDataInRealTime = true
    writer.add(sysInput)

    let micInput = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings)
    micInput.expectsMediaDataInRealTime = true
    writer.add(micInput)

    guard writer.startWriting() else {
      throw AECError.writeFailed(writer.error?.localizedDescription ?? "unknown")
    }
    writer.startSession(atSourceTime: .zero)

    let processor = DTLNAecEchoProcessor(modelSize: .medium)
    guard let modelBundle = Self.modelBundle() else {
      throw DTLNAecError.modelNotFound(Self.modelBundleName)
    }
    try processor.loadModels(from: modelBundle)

    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
    else {
      throw AECError.writeFailed("cannot create AVAudioFormat")
    }

    // Small staging buffers - bounded at ~one reader buffer + chunkSize (~8KB each)
    var sysBuf: [Float] = []
    var micBuf: [Float] = []
    var sysDone = false
    var micDone = false
    var sysWritten = 0
    var micWritten = 0

    while true {
      // A writer that has already failed accepts nothing, so decoding both
      // tracks and running inference to the end of the file buys nothing - and
      // at 16kHz/1024 that is ~56k wasted CoreML passes on an hour-long call.
      // The status check after the loop reports it.
      guard writer.status == .writing else { break }

      // Refill staging buffers from readers
      while sysBuf.count < chunkSize, !sysDone {
        if let sb = sysOutput.copyNextSampleBuffer() {
          sysBuf.append(contentsOf: extractSamples(from: sb))
        } else {
          sysDone = true
        }
      }
      while micBuf.count < chunkSize, !micDone {
        if let sb = micOutput.copyNextSampleBuffer() {
          micBuf.append(contentsOf: extractSamples(from: sb))
        } else {
          micDone = true
        }
      }

      let available = max(sysBuf.count, micBuf.count)
      if available == 0 { break }
      let n = min(chunkSize, available)

      // Feed system audio as far-end reference and write pass-through
      if !sysBuf.isEmpty {
        let count = min(n, sysBuf.count)
        let chunk = Array(sysBuf.prefix(count))
        sysBuf.removeFirst(count)
        processor.feedFarEnd(chunk)
        appendChunk(
          chunk, to: sysInput, writer: writer,
          sampleRate: sampleRate, offset: sysWritten, format: format)
        sysWritten += chunk.count
      }

      // Process mic through AEC and write cleaned audio
      if !micBuf.isEmpty {
        let count = min(n, micBuf.count)
        let chunk = Array(micBuf.prefix(count))
        micBuf.removeFirst(count)
        let cleaned = processor.processNearEnd(chunk)
        appendChunk(
          cleaned, to: micInput, writer: writer,
          sampleRate: sampleRate, offset: micWritten, format: format)
        micWritten += cleaned.count
      }
    }

    // Flush remaining processor state (~32ms)
    let flushed = processor.flush()
    if !flushed.isEmpty {
      appendChunk(
        flushed, to: micInput, writer: writer,
        sampleRate: sampleRate, offset: micWritten, format: format)
      micWritten += flushed.count
    }

    Log.info(
      Log.recorder, "aec",
      "streamed \(sysWritten) sys + \(micWritten) mic samples at 16kHz")

    sysInput.markAsFinished()
    micInput.markAsFinished()
    let finished = DispatchSemaphore(value: 0)
    writer.finishWriting { finished.signal() }
    finished.wait()

    guard writer.status == .completed else {
      throw AECError.writeFailed(writer.error?.localizedDescription ?? "writer failed")
    }
    return true
  }

  // MARK: - Helpers

  /// Synchronous track load for the blocking work queue. The async
  /// `loadTracks` would resume on the cooperative pool, which is exactly what
  /// this path must stay off of.
  nonisolated private static func loadAudioTracksBlocking(_ asset: AVURLAsset) throws
    -> [AVAssetTrack]
  {
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Result<[AVAssetTrack], Error>?
    asset.loadTracks(withMediaType: .audio) { tracks, error in
      result = tracks.map(Result.success) ?? .failure(error ?? AECError.readFailed("no tracks"))
      done.signal()
    }
    done.wait()
    return try result!.get()
  }

  nonisolated private static func extractSamples(from sampleBuffer: CMSampleBuffer) -> [Float] {
    guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return [] }
    let length = CMBlockBufferGetDataLength(blockBuffer)
    let floatCount = length / MemoryLayout<Float>.size
    var samples = [Float](repeating: 0, count: floatCount)
    samples.withUnsafeMutableBufferPointer { ptr in
      guard let base = ptr.baseAddress else { return }
      _ = CMBlockBufferCopyDataBytes(
        blockBuffer, atOffset: 0, dataLength: length, destination: base)
    }
    return samples
  }

  nonisolated private static func appendChunk(
    _ samples: [Float], to input: AVAssetWriterInput, writer: AVAssetWriter,
    sampleRate: Double, offset: Int, format: AVAudioFormat
  ) {
    while !input.isReadyForMoreMediaData {
      guard writer.status == .writing else { return }
      usleep(10_000)
    }
    if let sb = makeSampleBuffer(
      samples: samples, range: 0..<samples.count,
      sampleRate: sampleRate, timeOffset: offset, format: format)
    {
      if !input.append(sb) {
        Log.error(
          Log.recorder, "aec",
          "append failed at offset \(offset), status=\(writer.status.rawValue)")
      }
    }
  }

  nonisolated private static func makeSampleBuffer(
    samples: [Float], range: Range<Int>,
    sampleRate: Double, timeOffset: Int,
    format: AVAudioFormat
  ) -> CMSampleBuffer? {
    let count = range.count
    guard
      let pcmBuffer = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(count))
    else { return nil }
    pcmBuffer.frameLength = AVAudioFrameCount(count)

    guard let floatData = pcmBuffer.floatChannelData else { return nil }
    samples.withUnsafeBufferPointer { ptr in
      guard let base = ptr.baseAddress else { return }
      memcpy(
        floatData[0],
        base.advanced(by: range.lowerBound),
        count * MemoryLayout<Float>.size)
    }

    let asbd = format.streamDescription
    var formatDesc: CMFormatDescription?
    guard
      CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault, asbd: asbd,
        layoutSize: 0, layout: nil,
        magicCookieSize: 0, magicCookie: nil,
        extensions: nil, formatDescriptionOut: &formatDesc
      ) == noErr, let formatDesc
    else { return nil }

    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: Int32(sampleRate)),
      presentationTimeStamp: CMTime(value: Int64(timeOffset), timescale: Int32(sampleRate)),
      decodeTimeStamp: .invalid
    )

    var sampleBuffer: CMSampleBuffer?
    guard
      CMSampleBufferCreate(
        allocator: kCFAllocatorDefault,
        dataBuffer: nil,
        dataReady: false,
        makeDataReadyCallback: nil, refcon: nil,
        formatDescription: formatDesc,
        sampleCount: CMItemCount(count),
        sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 0, sampleSizeArray: nil,
        sampleBufferOut: &sampleBuffer
      ) == noErr
    else { return nil }

    guard let sampleBuffer,
      CMSampleBufferSetDataBufferFromAudioBufferList(
        sampleBuffer,
        blockBufferAllocator: kCFAllocatorDefault,
        blockBufferMemoryAllocator: kCFAllocatorDefault,
        flags: 0,
        bufferList: pcmBuffer.mutableAudioBufferList
      ) == noErr
    else { return nil }

    return sampleBuffer
  }
}

enum AECError: Error, LocalizedError {
  case readFailed(String)
  case writeFailed(String)

  var errorDescription: String? {
    switch self {
    case .readFailed(let msg): "AEC read failed: \(msg)"
    case .writeFailed(let msg): "AEC write failed: \(msg)"
    }
  }
}
