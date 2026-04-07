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

  // MARK: - Streaming Pipeline (background thread)

  nonisolated private static func run(
    inputURL: URL, outputURL: URL
  ) async throws {
    let sampleRate: Double = 16000
    let chunkSize = 1024

    let asset = AVURLAsset(url: inputURL)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    guard tracks.count >= 2 else {
      Log.info(Log.recorder, "aec", "single-track recording, skipping")
      return
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

    // AEC processor
    let processor = DTLNAecEchoProcessor(modelSize: .medium)
    try processor.loadModels(from: DTLNAec256.bundle)

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
    await writer.finishWriting()

    guard writer.status == .completed else {
      throw AECError.writeFailed(writer.error?.localizedDescription ?? "writer failed")
    }
  }

  // MARK: - Helpers

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
