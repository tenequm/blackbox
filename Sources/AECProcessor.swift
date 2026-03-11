@preconcurrency import AVFoundation
import CoreMedia
import DTLNAec256
import DTLNAecCoreML

/// Post-processes recorded audio to remove echo from the mic track using DTLN-aec.
/// Reads dual-track `audio.m4a`, runs echo cancellation on the mic track using
/// system audio as the far-end reference, writes `audio-processed.m4a` with both
/// tracks at 16kHz mono AAC. Original file is preserved for fallback.
enum AECProcessor {

  /// Process a recording directory. No-op if already processed or single-track.
  /// Fire-and-forget: errors are logged, original file is never modified.
  static func process(recordingDirectory: URL) async {
    let inputURL = recordingDirectory.appendingPathComponent("audio.m4a")
    let outputURL = recordingDirectory.appendingPathComponent("audio-processed.m4a")

    guard !FileManager.default.fileExists(atPath: outputURL.path) else { return }

    do {
      try await Task.detached {
        try await Self.run(inputURL: inputURL, outputURL: outputURL)
      }.value

      Log.info(Log.recorder, "aec", "echo cancellation complete")
    } catch {
      Log.error(Log.recorder, "aec", "failed: \(error.localizedDescription)")
      try? FileManager.default.removeItem(at: outputURL)
    }
  }

  // MARK: - Processing Pipeline (background thread)

  nonisolated private static func run(
    inputURL: URL, outputURL: URL
  ) async throws {
    let sampleRate: Double = 16000

    // Load asset and tracks - must use the SAME asset for reader and tracks
    let asset = AVURLAsset(url: inputURL)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    guard tracks.count >= 2 else {
      Log.info(Log.recorder, "aec", "single-track recording, skipping")
      return
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

    let systemSamples = try readTrack(asset: asset, track: tracks[0], settings: pcmSettings)
    let micSamples = try readTrack(asset: asset, track: tracks[1], settings: pcmSettings)

    guard !systemSamples.isEmpty, !micSamples.isEmpty else {
      Log.info(Log.recorder, "aec", "empty track(s), skipping")
      return
    }

    Log.info(
      Log.recorder, "aec",
      "read \(systemSamples.count) system + \(micSamples.count) mic samples at 16kHz")

    // Initialize echo canceller (256-unit model: ~15MB, 50dB suppression, 0.3s convergence)
    let processor = DTLNAecEchoProcessor(modelSize: .medium)
    try processor.loadModels(from: DTLNAec256.bundle)

    // Process in chunks: feed system audio as far-end reference, mic as near-end
    var cleaned: [Float] = []
    cleaned.reserveCapacity(micSamples.count)
    let chunkSize = 1024
    let maxLength = max(systemSamples.count, micSamples.count)
    var offset = 0

    while offset < maxLength {
      let end = min(offset + chunkSize, maxLength)
      if offset < systemSamples.count {
        processor.feedFarEnd(Array(systemSamples[offset..<min(end, systemSamples.count)]))
      }
      if offset < micSamples.count {
        let result = processor.processNearEnd(
          Array(micSamples[offset..<min(end, micSamples.count)]))
        cleaned.append(contentsOf: result)
      }
      offset = end
    }

    // Flush remaining buffered audio (~32ms)
    cleaned.append(contentsOf: processor.flush())

    Log.info(Log.recorder, "aec", "processed \(cleaned.count) samples")

    try await writeOutput(
      system: systemSamples, mic: cleaned, to: outputURL, sampleRate: sampleRate)
  }

  // MARK: - Track Reading

  nonisolated private static func readTrack(
    asset: AVURLAsset, track: AVAssetTrack, settings: [String: Any]
  ) throws -> [Float] {
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
    output.alwaysCopiesSampleData = false
    reader.add(output)
    guard reader.startReading() else {
      throw AECError.readFailed(reader.error?.localizedDescription ?? "unknown")
    }

    var samples: [Float] = []
    samples.reserveCapacity(Int(16000) * 60 * 10)  // ~10 min pre-alloc

    while let buffer = output.copyNextSampleBuffer() {
      guard let blockBuffer = CMSampleBufferGetDataBuffer(buffer) else { continue }
      let length = CMBlockBufferGetDataLength(blockBuffer)
      let floatCount = length / MemoryLayout<Float>.size
      let startIndex = samples.count
      samples.append(contentsOf: repeatElement(Float(0), count: floatCount))
      samples.withUnsafeMutableBufferPointer { ptr in
        _ = CMBlockBufferCopyDataBytes(
          blockBuffer, atOffset: 0, dataLength: length,
          destination: ptr.baseAddress!.advanced(by: startIndex))
      }
    }

    return samples
  }

  // MARK: - Output Writing

  nonisolated private static func writeOutput(
    system: [Float], mic: [Float], to url: URL, sampleRate: Double
  ) async throws {
    let aacSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: 1,
      AVEncoderBitRateKey: 48_000,
    ]

    let writer = try AVAssetWriter(url: url, fileType: .m4a)

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

    writeSamples(system, to: sysInput, writer: writer, sampleRate: sampleRate, label: "system")
    sysInput.markAsFinished()

    writeSamples(mic, to: micInput, writer: writer, sampleRate: sampleRate, label: "mic")
    micInput.markAsFinished()

    await writer.finishWriting()

    guard writer.status == .completed else {
      throw AECError.writeFailed(writer.error?.localizedDescription ?? "writer failed")
    }
  }

  nonisolated private static func writeSamples(
    _ samples: [Float], to input: AVAssetWriterInput, writer: AVAssetWriter,
    sampleRate: Double, label: String
  ) {
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    let chunkSize = 8192
    var offset = 0
    var appendCount = 0
    var failCount = 0

    while offset < samples.count {
      if !input.isReadyForMoreMediaData {
        guard writer.status == .writing else {
          Log.error(
            Log.recorder, "aec",
            "\(label) writer not writing (status=\(writer.status.rawValue)), aborting")
          break
        }
        usleep(10_000)
        continue
      }

      let end = min(offset + chunkSize, samples.count)
      if let sb = makeSampleBuffer(
        samples: samples, range: offset..<end,
        sampleRate: sampleRate, timeOffset: offset, format: format)
      {
        if input.append(sb) {
          appendCount += 1
        } else {
          failCount += 1
          if failCount == 1 {
            Log.error(
              Log.recorder, "aec",
              "\(label) append failed at offset \(offset), writer status=\(writer.status.rawValue), error=\(writer.error?.localizedDescription ?? "none")"
            )
          }
        }
      } else if offset == 0 {
        Log.error(Log.recorder, "aec", "\(label) makeSampleBuffer returned nil at offset 0")
      }
      offset = end
    }

    Log.info(
      Log.recorder, "aec",
      "\(label) wrote \(appendCount) chunks, \(failCount) failed")
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

    _ = samples.withUnsafeBufferPointer { ptr in
      memcpy(
        pcmBuffer.floatChannelData![0],
        ptr.baseAddress!.advanced(by: range.lowerBound),
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

    guard
      CMSampleBufferSetDataBufferFromAudioBufferList(
        sampleBuffer!,
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
