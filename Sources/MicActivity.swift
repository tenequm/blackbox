import AVFoundation
import os

nonisolated enum MicActivity {
  static let version = 1
  private static let queue = DispatchQueue(label: "blackbox.mic-attribution", qos: .utility)

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
    var micThresholdDBFS: Float = -50
    var usedAdaptiveMicThreshold = false
    var systemThresholdDBFS: Float = -105
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
    audio: URL, tokens: [TranscriptToken], check: () throws -> Void
  ) throws -> SpeakerAttribution? {
    try check()
    let asset = AVURLAsset(url: audio)
    let tracks = try asset.loadAudioTracksBlocking()
    guard tracks.count == 2 else { return nil }
    var parameters = Parameters()
    guard
      let system = try energies(asset, track: tracks[0], channels: 2, parameters, check),
      let mic = try energies(asset, track: tracks[1], channels: 1, parameters, check)
    else { return nil }
    try check()
    func noiseFloor(_ frames: [Frame]) -> Float {
      let sorted = frames.map(\.db).sorted()
      return sorted[Int(Double(sorted.count - 1) * parameters.noisePercentile)]
    }
    let adaptive = noiseFloor(mic) + parameters.micMarginDB
    parameters.usedAdaptiveMicThreshold = adaptive > parameters.micFloorDBFS
    parameters.micThresholdDBFS = max(adaptive, parameters.micFloorDBFS)
    parameters.systemThresholdDBFS = noiseFloor(system) + parameters.systemMarginDB
    let frames = localFrames(mic: mic, system: system, parameters)
    let indices = tokens.indices.filter {
      isLocal(tokens[$0], frames: frames, parameters)
    }
    try check()
    return SpeakerAttribution(
      version: version, parameters: parameters,
      sourceAudio: audio.lastPathComponent, localTokenIndices: indices, appliedAt: Date())
  }

  private static func energies(
    _ asset: AVAsset, track: AVAssetTrack, channels: Int,
    _ p: Parameters, _ check: () throws -> Void
  ) throws -> [Frame]? {
    try check()
    let reader = try AVAssetReader(asset: asset)
    // Preserve the native channel layout so a legacy mono system track cannot pass as stereo.
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: p.sampleRate,
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
      try check()
      guard let sample = output.copyNextSampleBuffer() else { break }
      guard let format = sample.formatDescription?.audioStreamBasicDescription,
        Int(format.mChannelsPerFrame) == channels
      else { return nil }
      let time = sample.presentationTimeStamp.convertScale(
        Int32(p.sampleRate), method: .roundHalfAwayFromZero)
      guard time.isNumeric, time.value <= Int64(Int32.max) * Int64(p.frameSamples),
        let block = sample.dataBuffer
      else {
        throw CocoaError(.fileReadCorruptFile)
      }
      let length = CMBlockBufferGetDataLength(block)
      guard length == sample.numSamples * channels * MemoryLayout<Float>.size,
        format.mSampleRate == Double(p.sampleRate)
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
        guard position >= 0, count > 0 || position.isMultiple(of: Int64(p.frameSamples)) else {
          continue
        }
        for channel in 0..<channels {
          let value = Double(samples[offset + channel])
          sum += value * value
        }
        count += 1
        if count == p.frameSamples {
          guard let index = Int32(exactly: position / Int64(count)) else {
            throw CocoaError(.fileReadCorruptFile)
          }
          let db = Float(10 * log10(sum / Double(count * channels) + p.energyEpsilon))
          if db.isFinite { frames.append(Frame(index: index, db: max(p.minimumDBFS, db))) }
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

  private static func localFrames(mic: [Frame], system: [Frame], _ p: Parameters) -> [Int32] {
    var active = mic.map { $0.db >= p.micThresholdDBFS }
    var previous: Int?
    for i in mic.indices where active[i] {
      if let previous, i - previous - 1 <= p.maximumGapFrames,
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
      if end - start >= p.minimumRunFrames {
        for frame in mic[start..<end] {
          while systemIndex < system.count, system[systemIndex].index < frame.index {
            systemIndex += 1
          }
          if systemIndex < system.count, system[systemIndex].index == frame.index,
            system[systemIndex].db < p.systemThresholdDBFS
          {
            result.append(frame.index)
          }
        }
      }
      start = end
    }
    return result
  }

  private static func isLocal(_ token: TranscriptToken, frames: [Int32], _ p: Parameters) -> Bool {
    guard let start = token.startMs, let end = token.endMs, start.isFinite, end.isFinite,
      start >= 0, end >= start
    else { return false }
    let frameMs = Double(p.frameSamples) * 1000 / Double(p.sampleRate)
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
    let lower = start - p.paddingMs
    let upper = end + p.paddingMs
    let local = localMilliseconds(before: upper) - localMilliseconds(before: lower)
    return upper > lower && local >= (upper - lower) * p.minimumLocalFraction
  }
}
