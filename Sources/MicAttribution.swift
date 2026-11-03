@preconcurrency import AVFoundation
import CoreMedia
import os

/// Finds the local user's own speech in a recording from its mic track, so the
/// transcript tokens spoken there can be labelled "You". Local only.
///
/// A mic-active frame counts as the local user only while the system track is
/// quiet: speaker leakage into the mic always has the system track active, so
/// it is rejected, and the cost is that the user's words spoken over someone
/// else keep the provider's label - the safe miss. See
/// `docs/plans/2611-03-mic-gated-you-attribution.md`.
nonisolated enum MicAttribution {
  /// Bumped whenever a constant or rule below changes, so stored results from
  /// an older rule are re-derived rather than trusted.
  static let version = 1

  enum Outcome: Equatable, Sendable {
    case attributed(localIndices: Set<Int>, micThresholdDb: Double, systemQuietBelowDb: Double)
    /// Nothing about this recording can be attributed; the reason is for logs.
    case ineligible(String)
  }

  /// Per 20 ms frame, in dBFS; NaN where the track has no audio for the frame.
  struct TrackEnergies: Sendable {
    var mic: [Double]
    var system: [Double]
  }

  static let sampleRate = 16_000.0
  static let frameSamples = 320
  static let frameMs = 20.0
  static let micFloorMarginDb = 25.0
  static let micMinimumDb = -50.0
  static let systemQuietMarginDb = 15.0
  static let maxGapFrames = 15
  static let minRunFrames = 10
  static let tokenPaddingMs = 40.0
  static let minLocalCoverage = 0.6

  /// `copyNextSampleBuffer` blocks its thread for the whole file, so the decode
  /// runs here rather than on the cooperative pool, where it can starve the
  /// libdispatch delivery it is waiting on (the rule `AECProcessor` follows).
  private static let workQueue = DispatchQueue(
    label: "com.tenequm.blackbox.mic-attribution", qos: .utility)

  /// Only the current writer's layout is attributed: two tracks, system stereo
  /// first, mic mono second (`RecordingPipeline`). v0.7 recordings are mono +
  /// mono and legacy ones have three tracks; track identity is never guessed.
  @concurrent
  static func analyze(audioURL: URL, tokens: [TranscriptToken]) async throws -> Outcome {
    let asset = AVURLAsset(url: audioURL)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    guard tracks.count == 2 else { return .ineligible("\(tracks.count) audio tracks") }
    let layout = [try await channelCount(of: tracks[0]), try await channelCount(of: tracks[1])]
    guard layout == [2, 1] else { return .ineligible("track channel layout \(layout)") }

    let flag = CancellationFlag()
    let energies = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<TrackEnergies, Error>) in
        workQueue.async {
          continuation.resume(with: Result { try decodeEnergies(audioURL, flag: flag) })
        }
      }
    } onCancel: {
      flag.cancel()
    }
    return attribute(tokens: tokens, energies: energies)
  }

  // MARK: - Rule

  static func attribute(tokens: [TranscriptToken], energies: TrackEnergies) -> Outcome {
    let micKnown = energies.mic.filter { !$0.isNaN }
    let systemKnown = energies.system.filter { !$0.isNaN }
    guard !micKnown.isEmpty else { return .ineligible("mic track has no audio") }
    guard !systemKnown.isEmpty else { return .ineligible("system track has no audio") }

    let micThreshold = max(percentile(micKnown, 0.10) + micFloorMarginDb, micMinimumDb)
    let systemQuietBelow = percentile(systemKnown, 0.10) + systemQuietMarginDb

    var micActive = energies.mic.map { !$0.isNaN && $0 > micThreshold }
    fillGaps(&micActive, upTo: maxGapFrames)
    dropRuns(&micActive, shorterThan: minRunFrames)
    // An unknown system frame fails the gate: missing reference audio is not
    // evidence that nobody remote was speaking.
    let local = micActive.indices.map { index in
      micActive[index] && index < energies.system.count
        && !energies.system[index].isNaN && energies.system[index] < systemQuietBelow
    }

    var localIndices = Set<Int>()
    for (index, token) in tokens.enumerated()
    where token.startMs.isFinite && token.endMs.isFinite && token.startMs >= 0
      && token.endMs >= token.startMs
    {
      let low = token.startMs - tokenPaddingMs
      let high = token.endMs + tokenPaddingMs
      let firstFrame = max(0, Int((low / frameMs).rounded(.down)))
      let lastFrame = min(local.count - 1, Int((high / frameMs).rounded(.down)))
      guard firstFrame <= lastFrame else { continue }
      var covered = 0.0
      for frame in firstFrame...lastFrame where local[frame] {
        let frameStart = Double(frame) * frameMs
        covered += max(0, min(high, frameStart + frameMs) - max(low, frameStart))
      }
      if covered / (high - low) >= minLocalCoverage { localIndices.insert(index) }
    }
    return .attributed(
      localIndices: localIndices, micThresholdDb: micThreshold,
      systemQuietBelowDb: systemQuietBelow)
  }

  static func percentile(_ values: [Double], _ fraction: Double) -> Double {
    let sorted = values.sorted()
    return sorted[Int((Double(sorted.count - 1) * fraction).rounded(.down))]
  }

  /// Fills inactive gaps of at most `limit` frames that sit between two active
  /// runs, so a pause inside a sentence does not split it.
  static func fillGaps(_ active: inout [Bool], upTo limit: Int) {
    var index = 0
    var lastActive: Int?
    while index < active.count {
      if active[index] {
        if let last = lastActive, index - last - 1 > 0, index - last - 1 <= limit {
          for gap in (last + 1)..<index { active[gap] = true }
        }
        lastActive = index
      }
      index += 1
    }
  }

  static func dropRuns(_ active: inout [Bool], shorterThan limit: Int) {
    var index = 0
    while index < active.count {
      guard active[index] else {
        index += 1
        continue
      }
      let start = index
      while index < active.count, active[index] { index += 1 }
      if index - start < limit {
        for frame in start..<index { active[frame] = false }
      }
    }
  }

  // MARK: - Decode (work queue)

  private static func channelCount(of track: AVAssetTrack) async throws -> UInt32 {
    let descriptions = try await track.load(.formatDescriptions)
    guard let description = descriptions.first,
      let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)
    else { return 0 }
    return basic.pointee.mChannelsPerFrame
  }

  private static func decodeEnergies(_ url: URL, flag: CancellationFlag) throws -> TrackEnergies {
    dispatchPrecondition(condition: .onQueue(workQueue))
    if flag.isCancelled { throw CancellationError() }
    let asset = AVURLAsset(url: url)
    let tracks = try loadAudioTracksBlocking(asset)
    guard tracks.count == 2 else { throw MicAttributionError.layoutChanged }
    let system = try frameEnergies(asset: asset, track: tracks[0], channels: 2, flag: flag)
    let mic = try frameEnergies(asset: asset, track: tracks[1], channels: 1, flag: flag)
    return TrackEnergies(mic: mic, system: system)
  }

  /// Frames are placed by absolute sample index from each buffer's timestamp,
  /// so a gap in the decoded timeline leaves its frames unknown instead of
  /// shifting everything after it. Stereo is reduced by averaging channel
  /// *power*: averaging samples would cancel opposite-phase content.
  private static func frameEnergies(
    asset: AVURLAsset, track: AVAssetTrack, channels: Int, flag: CancellationFlag
  ) throws -> [Double] {
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: channels,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
      ])
    output.alwaysCopiesSampleData = false
    reader.add(output)
    guard reader.startReading() else {
      throw MicAttributionError.readFailed(reader.error?.localizedDescription ?? "start")
    }

    var sums: [Double] = []
    var counts: [Int] = []
    while let buffer = output.copyNextSampleBuffer() {
      if flag.isCancelled {
        reader.cancelReading()
        throw CancellationError()
      }
      let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
      let frameCount = CMSampleBufferGetNumSamples(buffer)
      guard pts.isNumeric, pts.seconds >= 0, frameCount > 0,
        let block = CMSampleBufferGetDataBuffer(buffer)
      else { continue }
      let length = CMBlockBufferGetDataLength(block)
      var samples = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
      let copied = samples.withUnsafeMutableBytes { raw -> OSStatus in
        guard let base = raw.baseAddress else { return -1 }
        return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
      }
      guard copied == kCMBlockBufferNoErr else { continue }

      let available = min(frameCount, samples.count / channels)
      guard available > 0 else { continue }
      let firstSample = Int((pts.seconds * sampleRate).rounded())
      let lastFrame = (firstSample + available - 1) / frameSamples
      if sums.count <= lastFrame {
        sums.append(contentsOf: repeatElement(0, count: lastFrame + 1 - sums.count))
        counts.append(contentsOf: repeatElement(0, count: lastFrame + 1 - counts.count))
      }
      for offset in 0..<available {
        var power = 0.0
        for channel in 0..<channels {
          let sample = Double(samples[offset * channels + channel])
          power += sample * sample
        }
        let frame = (firstSample + offset) / frameSamples
        sums[frame] += power / Double(channels)
        counts[frame] += 1
      }
    }
    guard reader.status == .completed else {
      throw MicAttributionError.readFailed(reader.error?.localizedDescription ?? "incomplete")
    }
    return zip(sums, counts).map { sum, count in
      count >= frameSamples / 2 ? 10 * log10(sum / Double(count) + 1e-12) : .nan
    }
  }

  private static func loadAudioTracksBlocking(_ asset: AVURLAsset) throws -> [AVAssetTrack] {
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Result<[AVAssetTrack], Error>?
    asset.loadTracks(withMediaType: .audio) { tracks, error in
      result =
        tracks.map(Result.success) ?? .failure(error ?? MicAttributionError.readFailed("tracks"))
      done.signal()
    }
    done.wait()
    return try result!.get()
  }
}

nonisolated enum MicAttributionError: Error, LocalizedError {
  case readFailed(String)
  case layoutChanged

  var errorDescription: String? {
    switch self {
    case .readFailed(let detail): "mic attribution could not read the audio: \(detail)"
    case .layoutChanged: "the recording's tracks changed during mic attribution"
    }
  }
}

/// Lets a cancel reach a loop running on a dispatch queue, which Swift task
/// cancellation cannot see.
nonisolated final class CancellationFlag: Sendable {
  private let state = OSAllocatedUnfairLock(initialState: false)
  var isCancelled: Bool { state.withLock { $0 } }
  func cancel() { state.withLock { $0 = true } }
}
