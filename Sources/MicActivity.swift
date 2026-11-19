import AVFoundation
import os

nonisolated enum MicActivity {
  /// Bump to re-analyse recordings with an older attribution on next open.
  static let version = 1
  private static let queue = DispatchQueue(label: "blackbox.mic-attribution", qos: .utility)

  /// Section 4 of `docs/plans/2611-03-mic-gated-you-attribution.md` defines 20 ms frames,
  /// 300 ms gap bridging and a 200 ms minimum active run.
  struct Parameters: Codable, Sendable {
    var sampleRate = 16_000
    var frameSamples = 320
    var noisePercentile = 0.10
    var energyEpsilon = 1e-12
    var minimumDBFS: Float = -120
    var micMarginDB: Float = 25
    var micFloorDBFS: Float = -50
    var maximumGapFrames = 15
    var minimumRunFrames = 10
    var systemMarginDB: Float = 15
    var paddingMs = 40.0
    var minimumLocalFraction = 0.60
  }

  struct Thresholds: Codable, Sendable {
    let micThresholdDBFS: Float
    let usedAdaptiveMicThreshold: Bool
    let systemThresholdDBFS: Float
  }

  private struct Frame {
    let index: Int32
    let db: Float
  }

  static func analyze(audio: URL, tokens: [TranscriptToken]) async throws -> SpeakerAttribution? {
    let cancelled = OSAllocatedUnfairLock(initialState: false)
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        queue.async {
          continuation.resume(
            with: Result {
              try analyzeOnQueue(audio: audio, tokens: tokens) {
                if cancelled.withLock({ $0 }) { throw CancellationError() }
              }
            })
        }
      }
    } onCancel: {
      cancelled.withLock { $0 = true }
    }
  }

  private static func analyzeOnQueue(
    audio: URL, tokens: [TranscriptToken], checkCancelled: () throws -> Void
  ) throws -> SpeakerAttribution? {
    try checkCancelled()
    let asset = AVURLAsset(url: audio)
    let tracks = try asset.loadAudioTracksBlocking(missingTracks: CocoaError(.fileReadCorruptFile))
    guard tracks.count == 2 else {
      Log.info(Log.transcription, "attribution", "Skipping capture with an unsupported track count")
      return nil
    }
    guard let systemChannels = try channelCount(asset, track: tracks[0]),
      let micChannels = try channelCount(asset, track: tracks[1])
    else {
      Log.info(Log.transcription, "attribution", "Skipping capture with an empty audio track")
      return nil
    }
    guard systemChannels == 2, micChannels == 1 else {
      Log.info(Log.transcription, "attribution", "Skipping unsupported audio channel layout")
      return nil
    }
    let parameters = Parameters()
    guard
      let system = try energies(asset, track: tracks[0], channels: 2, parameters, checkCancelled),
      let mic = try energies(asset, track: tracks[1], channels: 1, parameters, checkCancelled)
    else {
      Log.info(Log.transcription, "attribution", "Skipping tracks without complete audio frames")
      return nil
    }
    try checkCancelled()
    func noiseFloor(_ frames: [Frame]) -> Float {
      let sorted = frames.map(\.db).sorted()
      return sorted[Int(Double(sorted.count - 1) * parameters.noisePercentile)]
    }
    let adaptive = noiseFloor(mic) + parameters.micMarginDB
    let thresholds = Thresholds(
      micThresholdDBFS: max(adaptive, parameters.micFloorDBFS),
      usedAdaptiveMicThreshold: adaptive > parameters.micFloorDBFS,
      systemThresholdDBFS: noiseFloor(system) + parameters.systemMarginDB)
    let frames = localFrames(mic: mic, system: system, parameters, thresholds)
    let indices = tokens.indices.filter {
      isLocal(tokens[$0], frames: frames, parameters)
    }
    try checkCancelled()
    return SpeakerAttribution(
      version: version, parameters: parameters,
      thresholds: thresholds, localTokenIndices: indices, appliedAt: Date())
  }

  /// A passthrough output exposes the source channel layout without decoding PCM.
  private static func channelCount(_ asset: AVAsset, track: AVAssetTrack) throws -> UInt32? {
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    guard reader.canAdd(output) else { throw CocoaError(.fileReadCorruptFile) }
    reader.add(output)
    guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
    defer { reader.cancelReading() }
    return output.copyNextSampleBuffer()?.formatDescription?.audioStreamBasicDescription?
      .mChannelsPerFrame
  }

  private static func energies(
    _ asset: AVAsset, track: AVAssetTrack, channels: Int,
    _ parameters: Parameters, _ checkCancelled: () throws -> Void
  ) throws -> [Frame]? {
    try checkCancelled()
    let reader = try AVAssetReader(asset: asset)
    // Preserve the native channel layout so a legacy mono system track cannot pass as stereo.
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: parameters.sampleRate,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
      ])
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { throw CocoaError(.fileReadCorruptFile) }
    reader.add(output)
    guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
    defer { reader.cancelReading() }

    var frames: [Frame] = []
    var nextSample: Int64?
    var sum = 0.0
    var count = 0
    while true {
      try checkCancelled()
      guard let sample = output.copyNextSampleBuffer() else { break }
      guard let format = sample.formatDescription?.audioStreamBasicDescription,
        Int(format.mChannelsPerFrame) == channels
      else { return nil }
      let time = sample.presentationTimeStamp.convertScale(
        Int32(parameters.sampleRate), method: .roundHalfAwayFromZero)
      guard time.isNumeric, time.value <= Int64(Int32.max) * Int64(parameters.frameSamples),
        let block = sample.dataBuffer
      else {
        throw CocoaError(.fileReadCorruptFile)
      }
      let length = CMBlockBufferGetDataLength(block)
      guard length == sample.numSamples * channels * MemoryLayout<Float>.size,
        format.mSampleRate == Double(parameters.sampleRate)
      else { throw CocoaError(.fileReadCorruptFile) }
      var samples = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
      guard !samples.isEmpty else { continue }
      let result = samples.withUnsafeMutableBytes {
        CMBlockBufferCopyDataBytes(
          block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
      }
      guard result == noErr else { throw CocoaError(.fileReadCorruptFile) }

      var position = time.value
      if position != nextSample {
        guard nextSample.map({ position >= $0 }) ?? true else {
          throw CocoaError(.fileReadCorruptFile)
        }
        sum = 0
        count = 0
      }
      for offset in stride(from: 0, to: samples.count, by: channels) {
        defer { position += 1 }
        guard position >= 0, count > 0 || position.isMultiple(of: Int64(parameters.frameSamples))
        else {
          continue
        }
        for channel in 0..<channels {
          let value = Double(samples[offset + channel])
          sum += value * value
        }
        count += 1
        if count == parameters.frameSamples {
          guard let index = Int32(exactly: position / Int64(count)) else {
            throw CocoaError(.fileReadCorruptFile)
          }
          let db = Float(10 * log10(sum / Double(count * channels) + parameters.energyEpsilon))
          if db.isFinite { frames.append(Frame(index: index, db: max(parameters.minimumDBFS, db))) }
          count = 0
          sum = 0
        }
      }
      nextSample = position
    }
    guard reader.status == .completed else {
      throw reader.error ?? CocoaError(.fileReadCorruptFile)
    }
    return frames.isEmpty ? nil : frames
  }

  private static func localFrames(
    mic: [Frame], system: [Frame], _ parameters: Parameters, _ thresholds: Thresholds
  ) -> [Int32] {
    var active = mic.map { $0.db >= thresholds.micThresholdDBFS }
    var previous: Int?
    for i in mic.indices where active[i] {
      if let previous, i - previous - 1 <= parameters.maximumGapFrames,
        Int(mic[i].index) - Int(mic[previous].index) == i - previous
      {
        for gap in (previous + 1)..<i { active[gap] = true }
      }
      previous = i
    }
    var result: [Int32] = []
    var systemIndex = 0
    var start = 0
    while start < mic.count {
      guard active[start] else {
        start += 1
        continue
      }
      var end = start + 1
      while end < mic.count, active[end], mic[end].index - mic[end - 1].index == 1 { end += 1 }
      if end - start >= parameters.minimumRunFrames {
        for frame in mic[start..<end] {
          while systemIndex < system.count, system[systemIndex].index < frame.index {
            systemIndex += 1
          }
          if systemIndex < system.count, system[systemIndex].index == frame.index,
            system[systemIndex].db < thresholds.systemThresholdDBFS
          {
            result.append(frame.index)
          }
        }
      }
      start = end
    }
    return result
  }

  private static func isLocal(_ token: TranscriptToken, frames: [Int32], _ parameters: Parameters)
    -> Bool
  {
    guard let start = token.startMs, let end = token.endMs, start.isFinite, end.isFinite,
      start >= 0, end >= start
    else { return false }
    let frameMs = Double(parameters.frameSamples) * 1000 / Double(parameters.sampleRate)
    // Integral of the local mask up to an arbitrary timestamp, including fractional edge frames.
    func localMilliseconds(before time: Double) -> Double {
      var low = 0
      var high = frames.count
      while low < high {
        let mid = low + (high - low) / 2
        if Double(frames[mid]) * frameMs < time { low = mid + 1 } else { high = mid }
      }
      guard low > 0 else { return 0 }
      return Double(low - 1) * frameMs + min(frameMs, time - Double(frames[low - 1]) * frameMs)
    }
    let lower = start - parameters.paddingMs
    let upper = end + parameters.paddingMs
    let local = localMilliseconds(before: upper) - localMilliseconds(before: lower)
    return upper > lower && local >= (upper - lower) * parameters.minimumLocalFraction
  }
}
