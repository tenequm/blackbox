@preconcurrency import AVFoundation
import CoreMedia

enum RecordingTrackKind: String, Sendable {
  case system
  case mic
}

/// Controls when the writer session starts relative to first-sample arrivals.
///
/// - `.preserveAllContent` (manual recordings): start the session on the first
///   sample of any track. The late-firing track gets leading silence filled
///   from sessionStart to its first PTS. Every captured sample is written -
///   no pre-session drops, no pending window. Short recordings always produce
///   output.
///
/// - `.waitForAllTracks` (auto recordings): defer the session until every
///   enabled track has delivered at least one sample, then start at
///   `max(systemTrack.firstPTS, micTrack.firstPTS)`. Early-track head content (samples
///   from before the second track arrived) is dropped. A 500ms timeout (PTS
///   span **or** wall-clock elapsed since first sample) guards against a
///   second track that never arrives. Produces cleaner output with no silent
///   intro, at the cost of ~50-300ms of head content from whichever track
///   fired first. Short recordings where both tracks never fired + stop() hits
///   before the timeout produce no output.
enum SessionAlignmentMode: String, Sendable {
  case preserveAllContent
  case waitForAllTracks
}

nonisolated struct TrackDiagnostics: Sendable {
  var buffersReceived = 0
  var buffersAppended = 0
  var buffersDroppedNotReady = 0
  var buffersDroppedBeforeSession = 0
  var buffersAppendFailed = 0
  var gapsFilled = 0
  var leadingSilenceBuffers = 0
  var leadingSilenceSeconds = 0.0
  var tailPaddingBuffers = 0
  var tailPaddingSeconds = 0.0
}

nonisolated struct RecordingDiagnostics: Sendable {
  var sessionStartTrack: RecordingTrackKind?
  var sessionStartPTS: Double?
  var system = TrackDiagnostics()
  var mic = TrackDiagnostics()
  var sessionStartTimedOut = false

  subscript(track: RecordingTrackKind) -> TrackDiagnostics {
    get {
      switch track {
      case .system: return system
      case .mic: return mic
      }
    }
    set {
      switch track {
      case .system: system = newValue
      case .mic: mic = newValue
      }
    }
  }
}

/// Per-track live state maintained inside `RecordingPipeline`. All mutation
/// happens on AudioRecorder's `audioQueue`, same as the pipeline itself, so
/// the fact that `AVAssetWriterInput` is not `Sendable` is handled by the
/// enclosing `nonisolated(unsafe)` storage. Marked `nonisolated` explicitly
/// because the package-wide `defaultIsolation(MainActor.self)` setting would
/// otherwise pin it to the main actor, which conflicts with being stored in a
/// `nonisolated(unsafe)` field inside a non-MainActor class.
nonisolated struct TrackState {
  var input: AVAssetWriterInput?
  var firstPTS: CMTime = .invalid
  var lastSeenPTS: CMTime = .invalid
  var nextExpected: CMTime = .invalid
}

final class RecordingPipeline: @unchecked Sendable {
  nonisolated static let writerSampleRate: Double = 48_000

  /// Output format for the writer pipeline: mono 48 kHz interleaved Float32.
  /// Hoisted so `resampleToMono48k` does not allocate a fresh `AVAudioFormat`
  /// on every buffer (~200/s combined across system + mic tracks).
  nonisolated static let monoFormat48k: AVAudioFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: 48_000,
    channels: 1,
    interleaved: true
  )!

  nonisolated let bundleID: String?
  nonisolated let appName: String
  nonisolated let micEnabled: Bool
  nonisolated let saveDirectory: URL
  nonisolated let alignmentMode: SessionAlignmentMode

  nonisolated let onFailure: (@Sendable (RecorderFailure) -> Void)?
  nonisolated let onAudioLevel: (@Sendable (Float) -> Void)?

  /// Invoked once per `start()`, when the first sample arrives under
  /// `.waitForAllTracks`. AudioRecorder uses this to schedule a one-shot
  /// `tryStartSessionFromTimeout()` call ~500ms later, so that the wall-clock
  /// timeout fires even if the second track stops delivering samples entirely
  /// (i.e. no later `appendSample` calls to drive the PTS-based check).
  nonisolated let armSessionStartTimeout: (@Sendable () -> Void)?

  nonisolated(unsafe) private var writer: AVAssetWriter?
  nonisolated(unsafe) private var systemTrack = TrackState()
  nonisolated(unsafe) private var micTrack = TrackState()
  nonisolated(unsafe) private var sessionStarted = false
  nonisolated(unsafe) private var sessionStartTime: CMTime = .invalid
  nonisolated(unsafe) private var sessionPending = true
  nonisolated(unsafe) private var firstSampleWallClock: DispatchTime?
  nonisolated(unsafe) private var stopped = false

  /// Maximum PTS-time we wait for the second track to fire before giving up and
  /// starting the session on whichever track has already delivered samples.
  /// Measured in sample time (not wall clock) so it is deterministic in tests.
  nonisolated static let sessionStartTimeoutSeconds: Double = 0.5
  nonisolated(unsafe) private var fileURL: URL?
  nonisolated(unsafe) private var lastLevelTime: UInt64 = 0
  nonisolated(unsafe) private var pendingMaxLevel: Float = 0
  nonisolated(unsafe) private var writerFailureReported = false
  nonisolated(unsafe) private var diagnostics = RecordingDiagnostics()

  nonisolated private subscript(track: RecordingTrackKind) -> TrackState {
    get {
      switch track {
      case .system: return systemTrack
      case .mic: return micTrack
      }
    }
    set {
      switch track {
      case .system: systemTrack = newValue
      case .mic: micTrack = newValue
      }
    }
  }

  nonisolated init(
    bundleID: String? = nil,
    appName: String,
    micEnabled: Bool,
    saveDirectory: URL,
    alignmentMode: SessionAlignmentMode,
    onFailure: (@Sendable (RecorderFailure) -> Void)? = nil,
    onAudioLevel: (@Sendable (Float) -> Void)? = nil,
    armSessionStartTimeout: (@Sendable () -> Void)? = nil
  ) {
    self.bundleID = bundleID
    self.appName = appName
    self.micEnabled = micEnabled
    self.saveDirectory = saveDirectory
    self.alignmentMode = alignmentMode
    self.onFailure = onFailure
    self.onAudioLevel = onAudioLevel
    self.armSessionStartTimeout = armSessionStartTimeout
  }

  nonisolated var isSessionStarted: Bool { sessionStarted }

  nonisolated var currentDiagnostics: RecordingDiagnostics { diagnostics }

  nonisolated func start() throws {
    try FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)

    let attrs = try FileManager.default.attributesOfFileSystem(forPath: saveDirectory.path)
    if let freeBytes = attrs[.systemFreeSize] as? Int64, freeBytes < 50_000_000 {
      throw NSError(
        domain: "Blackbox",
        code: 1,
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
      speakers: [:],
      perAppBundleID: bundleID,
      perAppName: nil,
      trackCount: 1 + (micEnabled ? 1 : 0)
    )
    try metadata.save(in: dirURL)

    let audioSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: Self.writerSampleRate,
      AVNumberOfChannelsKey: 1,
      AVEncoderBitRateKey: 64_000,
    ]

    let newWriter = try AVAssetWriter(url: audioURL, fileType: .m4a)
    newWriter.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)

    let systemInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
    systemInput.expectsMediaDataInRealTime = true
    newWriter.add(systemInput)

    var newMicInput: AVAssetWriterInput?
    if micEnabled {
      let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
      input.expectsMediaDataInRealTime = true
      newWriter.add(input)
      newMicInput = input
    }

    guard newWriter.startWriting() else {
      let err = newWriter.error
      Log.error(
        Log.recorder, "recorder",
        "writer startWriting failed: \(err?.localizedDescription ?? "unknown")")
      try? FileManager.default.removeItem(at: dirURL)
      throw err ?? RecorderError.writerFailed
    }

    writer = newWriter
    systemTrack = TrackState(input: systemInput)
    micTrack = TrackState(input: newMicInput)
    fileURL = dirURL
    sessionStarted = false
    sessionStartTime = .invalid
    sessionPending = true
    firstSampleWallClock = nil
    stopped = false
    writerFailureReported = false
    diagnostics = RecordingDiagnostics()
  }

  nonisolated func appendSystemSample(_ sampleBuffer: CMSampleBuffer) {
    appendSample(sampleBuffer, to: .system)
    publishAudioLevel(sampleBuffer)
  }

  nonisolated func appendMicSample(_ sampleBuffer: CMSampleBuffer) {
    guard micEnabled else { return }
    appendSample(sampleBuffer, to: .mic)
    publishAudioLevel(sampleBuffer)
  }

  @discardableResult
  nonisolated func stop() async -> URL? {
    stopped = true

    let finalEndTime = [systemTrack.nextExpected, micTrack.nextExpected]
      .filter(\.isValid)
      .max { $0.seconds < $1.seconds }

    if let finalEndTime {
      padTailIfNeeded(for: .system, to: finalEndTime)
      padTailIfNeeded(for: .mic, to: finalEndTime)
    }

    systemTrack.input?.markAsFinished()
    micTrack.input?.markAsFinished()

    let wasStarted = sessionStarted
    let capturedWriter = writer
    let capturedFileURL = fileURL

    systemTrack = TrackState()
    micTrack = TrackState()
    writer = nil
    fileURL = nil
    sessionStarted = false
    sessionStartTime = .invalid
    sessionPending = true
    firstSampleWallClock = nil

    guard let capturedWriter else { return nil }
    guard wasStarted else {
      capturedWriter.cancelWriting()
      if let capturedFileURL { try? FileManager.default.removeItem(at: capturedFileURL) }
      return nil
    }

    nonisolated(unsafe) let writerForTimeout = capturedWriter
    let timeoutTask = Task.detached {
      try await Task.sleep(for: .seconds(5))
      Log.error(Log.recorder, "recorder", "finishWriting timed out after 5s, cancelling")
      writerForTimeout.cancelWriting()
    }
    await capturedWriter.finishWriting()
    timeoutTask.cancel()

    if capturedWriter.status == .failed {
      Log.error(
        Log.recorder, "recorder",
        "writer failed: \(capturedWriter.error?.localizedDescription ?? "unknown")")
    } else if capturedWriter.status == .cancelled {
      Log.error(
        Log.recorder, "recorder",
        "finishWriting cancelled by timeout - file may be incomplete")
    }

    if capturedWriter.status == .completed || capturedWriter.status == .cancelled {
      return capturedFileURL
    }
    return nil
  }

  nonisolated private func startSessionIfNeeded(at pts: CMTime, track: RecordingTrackKind) {
    guard !sessionStarted, let writer else { return }
    writer.startSession(atSourceTime: pts)
    sessionStarted = true
    sessionStartTime = pts
    diagnostics.sessionStartTrack = track
    diagnostics.sessionStartPTS = pts.seconds
  }

  /// `.waitForAllTracks` only. Defers session start until every enabled track
  /// has delivered its first sample, anchoring at `max(first_sys_pts, first_mic_pts)`
  /// so both tracks begin with real content (no silent intro). A 500ms timeout
  /// falls back to whichever track is firing; it fires when *either* the sample-PTS
  /// span **or** wall-clock elapsed since the first sample crosses the threshold.
  /// PTS-span keeps tests deterministic; wall-clock handles the case where a
  /// track stops delivering samples entirely after its first buffer.
  nonisolated private func tryStartSession() {
    guard sessionPending, !stopped else { return }

    let firstSystemPTS = systemTrack.firstPTS
    let firstMicPTS = micTrack.firstPTS
    let systemReady = firstSystemPTS.isValid
    let micReady = !micEnabled || firstMicPTS.isValid

    if systemReady && micReady {
      let sessionPTS: CMTime
      let track: RecordingTrackKind
      if micEnabled, firstMicPTS.isValid {
        if CMTimeCompare(firstMicPTS, firstSystemPTS) >= 0 {
          sessionPTS = firstMicPTS
          track = .mic
        } else {
          sessionPTS = firstSystemPTS
          track = .system
        }
      } else {
        sessionPTS = firstSystemPTS
        track = .system
      }
      startSessionIfNeeded(at: sessionPTS, track: track)
      sessionPending = false
      return
    }

    // Timeout path: one track has fired but the other has not. Start the session
    // on whichever track is firing so we do not drop the whole recording waiting.
    let firingTrack: RecordingTrackKind?
    if systemReady && !micReady {
      firingTrack = .system
    } else if !systemReady && micReady {
      firingTrack = .mic
    } else {
      firingTrack = nil
    }
    guard let firingTrack else { return }
    let firingFirst = self[firingTrack].firstPTS
    let firingLatest = self[firingTrack].lastSeenPTS
    guard firingFirst.isValid, firingLatest.isValid else { return }

    let ptsElapsed = CMTimeGetSeconds(firingLatest - firingFirst)
    let wallClockElapsed: Double
    if let firstSampleWallClock {
      wallClockElapsed =
        Double(DispatchTime.now().uptimeNanoseconds - firstSampleWallClock.uptimeNanoseconds) / 1e9
    } else {
      wallClockElapsed = 0
    }

    if ptsElapsed >= Self.sessionStartTimeoutSeconds
      || wallClockElapsed >= Self.sessionStartTimeoutSeconds
    {
      Log.info(
        Log.recorder, "recorder",
        "session start timed out waiting for \(firingTrack == .system ? "mic" : "system") (pts_elapsed=\(String(format: "%.3f", ptsElapsed))s wall=\(String(format: "%.3f", wallClockElapsed))s), starting on \(firingTrack.rawValue) alone"
      )
      startSessionIfNeeded(at: firingFirst, track: firingTrack)
      diagnostics.sessionStartTimedOut = true
      sessionPending = false
    }
  }

  /// External entry point for the delayed timeout poke scheduled by
  /// `armSessionStartTimeout`. Must be called on the same serial queue that
  /// drives `appendSample` so the unsafe state remains single-threaded.
  nonisolated func tryStartSessionFromTimeout() {
    tryStartSession()
  }

  nonisolated private func appendSample(
    _ sampleBuffer: CMSampleBuffer,
    to track: RecordingTrackKind
  ) {
    diagnostics[track].buffersReceived += 1
    guard !stopped else { return }

    let pts = sampleBuffer.presentationTimeStamp
    let endTime = Self.bufferEndTime(sampleBuffer)

    // Record first-seen and latest-seen PTS for the session-start gate.
    if !self[track].firstPTS.isValid {
      self[track].firstPTS = pts
    }
    self[track].lastSeenPTS = pts
    // Only .waitForAllTracks uses the wall-clock timeout fallback. Capturing
    // this under .preserveAllContent would be a dead write since that mode
    // starts the session immediately without ever consulting the timeout.
    if alignmentMode == .waitForAllTracks, firstSampleWallClock == nil {
      firstSampleWallClock = DispatchTime.now()
      // Ask the owner (AudioRecorder) to schedule a delayed poke so that the
      // wall-clock timeout still fires if the other track never delivers a
      // single sample. Without this, `tryStartSession` would only be re-run on
      // further sample arrivals on the already-firing track.
      armSessionStartTimeout?()
    }

    if sessionPending {
      switch alignmentMode {
      case .preserveAllContent:
        // Manual recordings: start the session immediately on this track's first
        // sample. The other track will get leading silence filled from sessionStart
        // to its own first PTS when it eventually arrives. No content is dropped,
        // short recordings always produce output.
        startSessionIfNeeded(at: pts, track: track)
        sessionPending = false
      case .waitForAllTracks:
        tryStartSession()
      }
    }

    if sessionPending {
      // .waitForAllTracks path: still waiting for the other track. Sample is
      // discarded. Content loss is limited to the pre-alignment window of the
      // early track (first sample up to sessionStart) - content which has no
      // counterpart on the other track anyway.
      diagnostics[track].buffersDroppedBeforeSession += 1
      return
    }

    // Session now active. If this sample's PTS is earlier than sessionStart
    // (possible on D9 over-compensation or extreme clock skew), drop it rather
    // than letting AVAssetWriter reject it.
    if sessionStartTime.isValid, CMTimeCompare(pts, sessionStartTime) < 0 {
      diagnostics[track].buffersDroppedBeforeSession += 1
      return
    }

    let nextExpected = self[track].nextExpected

    if !nextExpected.isValid, sessionStartTime.isValid,
      let input = self[track].input,
      CMTimeCompare(pts, sessionStartTime) > 0
    {
      let leadSeconds = CMTimeGetSeconds(pts - sessionStartTime)
      if leadSeconds > 0.001 {
        // Use fillGapFully with tight bounds: in the `.waitForAllTracks` timeout
        // fallback and in `.preserveAllContent` mode while the other track is
        // actively writing, the writer is not empty and back-pressure is possible.
        // 20 x 5ms = 100ms max stall on audioQueue, which is short enough not to
        // meaningfully starve live capture but retries enough to push through
        // transient encoder back-pressure so we don't lose the real sample that
        // follows.
        let (leadingBuffers, _) = Self.fillGapFully(
          from: sessionStartTime,
          to: pts,
          channelCount: 1,
          sampleRate: Self.writerSampleRate,
          input: input,
          maxSpinAttempts: 20,
          spinInterval: 0.005
        )
        if leadingBuffers > 0 {
          diagnostics[track].leadingSilenceBuffers += leadingBuffers
          diagnostics[track].leadingSilenceSeconds += leadSeconds
          Log.info(
            Log.recorder, "recorder",
            "\(track.rawValue): filled \(String(format: "%.3f", leadSeconds))s leading silence with \(leadingBuffers) buffers"
          )
        }
      }
    }

    if let input = self[track].input, nextExpected.isValid {
      let gap = CMTimeGetSeconds(pts - nextExpected)
      if gap > 0.005 {
        let (filled, _) = Self.fillGap(
          from: nextExpected,
          to: pts,
          channelCount: 1,
          sampleRate: Self.writerSampleRate,
          input: input
        )
        if filled > 0 {
          diagnostics[track].gapsFilled += filled
          Log.info(
            Log.recorder, "recorder",
            "\(track.rawValue): filled \(String(format: "%.3f", gap))s gap with \(filled) silence buffers"
          )
        }
      }
    }
    self[track].nextExpected = endTime

    guard let input = self[track].input, input.isReadyForMoreMediaData else {
      diagnostics[track].buffersDroppedNotReady += 1
      return
    }

    if input.append(sampleBuffer) {
      diagnostics[track].buffersAppended += 1
    } else {
      diagnostics[track].buffersAppendFailed += 1
      Log.recorder.warning("\(track.rawValue) append failed for \(self.appName, privacy: .public)")
      reportWriterFailureIfNeeded()
    }
  }

  nonisolated private func padTailIfNeeded(for track: RecordingTrackKind, to finalEndTime: CMTime) {
    let nextExpected = self[track].nextExpected
    guard let input = self[track].input, nextExpected.isValid,
      nextExpected < finalEndTime
    else { return }

    let tailSeconds = CMTimeGetSeconds(finalEndTime - nextExpected)
    let (buffers, samples) = Self.fillGapFully(
      from: nextExpected,
      to: finalEndTime,
      channelCount: 1,
      sampleRate: Self.writerSampleRate,
      input: input
    )
    guard buffers > 0 else {
      Log.error(
        Log.recorder, "recorder",
        "\(track.rawValue): tail padding failed - no buffers written for \(String(format: "%.3f", tailSeconds))s gap"
      )
      return
    }

    diagnostics[track].gapsFilled += buffers
    diagnostics[track].tailPaddingBuffers += buffers
    diagnostics[track].tailPaddingSeconds += tailSeconds

    let samplesExpected = Int(tailSeconds * Self.writerSampleRate)
    let residual = samplesExpected - samples
    if residual > 0 {
      Log.error(
        Log.recorder, "recorder",
        "\(track.rawValue): tail padding short by \(residual) samples (\(String(format: "%.3f", Double(residual) / Self.writerSampleRate))s)"
      )
    } else {
      Log.info(
        Log.recorder, "recorder",
        "\(track.rawValue): padded tail with \(buffers) buffers (\(samples) samples)")
    }
  }

  nonisolated private func reportWriterFailureIfNeeded() {
    guard !writerFailureReported, let writer, writer.status == .failed else { return }
    writerFailureReported = true
    let description = writer.error?.localizedDescription ?? "unknown writer error"
    Log.error(Log.recorder, "recorder", "writer entered failed state: \(description)")
    onFailure?(.other(description))
  }

  nonisolated private func publishAudioLevel(_ sampleBuffer: CMSampleBuffer) {
    guard onAudioLevel != nil else { return }
    guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

    var length = 0
    var dataPointer: UnsafeMutablePointer<Int8>?
    guard
      CMBlockBufferGetDataPointer(
        blockBuffer,
        atOffset: 0,
        lengthAtOffsetOut: nil,
        totalLengthOut: &length,
        dataPointerOut: &dataPointer
      ) == noErr,
      let dataPointer,
      length > 0
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
    if rms > pendingMaxLevel { pendingMaxLevel = rms }

    let now = DispatchTime.now().uptimeNanoseconds
    guard now - lastLevelTime >= 250_000_000 else { return }
    lastLevelTime = now
    let level = pendingMaxLevel
    pendingMaxLevel = 0
    onAudioLevel?(level)
  }

  nonisolated static func bufferEndTime(_ sampleBuffer: CMSampleBuffer) -> CMTime {
    let pts = sampleBuffer.presentationTimeStamp
    let duration = sampleBuffer.duration
    if duration.isValid && !duration.isIndefinite {
      return CMTimeAdd(pts, duration)
    }

    guard let formatDescription = sampleBuffer.formatDescription else { return .invalid }
    let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
    guard let rate = asbd?.pointee.mSampleRate, rate > 0 else { return .invalid }
    return CMTimeAdd(pts, CMTime(value: Int64(sampleBuffer.numSamples), timescale: Int32(rate)))
  }

  nonisolated static func fillGap(
    from start: CMTime,
    to end: CMTime,
    channelCount: Int,
    sampleRate: Double,
    input: AVAssetWriterInput
  ) -> (buffers: Int, samples: Int) {
    let gapSeconds = CMTimeGetSeconds(end - start)
    let gapSamples = Int(gapSeconds * sampleRate)
    guard gapSamples > 0 else { return (0, 0) }

    let chunkSize = 1024
    var written = 0
    var samplesWritten = 0
    var offset = 0

    while offset < gapSamples {
      let count = min(chunkSize, gapSamples - offset)
      let pts = CMTimeAdd(start, CMTime(value: Int64(offset), timescale: Int32(sampleRate)))

      guard
        let sampleBuffer = makeSilentSampleBuffer(
          channelCount: channelCount,
          sampleCount: count,
          sampleRate: sampleRate,
          presentationTimeStamp: pts
        )
      else {
        Log.error(
          Log.recorder, "recorder",
          "silence buffer creation failed at offset \(offset)/\(gapSamples)")
        break
      }

      guard input.isReadyForMoreMediaData else {
        Log.info(
          Log.recorder, "recorder",
          "silence fill interrupted by back-pressure at \(written)/\(gapSamples / chunkSize) chunks"
        )
        break
      }

      if input.append(sampleBuffer) {
        written += 1
        samplesWritten += count
      } else {
        Log.error(
          Log.recorder, "recorder",
          "silence append failed at offset \(offset)/\(gapSamples)")
        break
      }
      offset += count
    }

    return (written, samplesWritten)
  }

  /// Drives `fillGap` in a retry loop until `end` is reached or the writer input
  /// refuses further samples for `maxSpinAttempts × spinInterval`.
  ///
  /// Uses `Thread.sleep` on the calling thread to wait out back-pressure. The
  /// sleep runs on `audioQueue` and will block any other work already queued
  /// there (CATap IO proc dispatches, AVAudioEngine tap dispatches) until it
  /// returns. Pick bounds carefully:
  ///
  /// - `padTailIfNeeded` inside `stop()`: caller already torn down IO proc and
  ///   engine tap, so blocking `audioQueue` is free. Default bounds (200 x 5ms
  ///   = 1s) are fine.
  /// - Leading silence during an active recording (`.waitForAllTracks` timeout
  ///   fallback, or `.preserveAllContent` late track first-fire): live capture
  ///   is still flowing. Use **short** bounds (20 x 5ms = 100ms max stall) so
  ///   we retry transient encoder back-pressure without starving more than a
  ///   handful of capture callbacks.
  nonisolated static func fillGapFully(
    from start: CMTime,
    to end: CMTime,
    channelCount: Int,
    sampleRate: Double,
    input: AVAssetWriterInput,
    maxSpinAttempts: Int = 200,
    spinInterval: TimeInterval = 0.005
  ) -> (buffers: Int, samples: Int) {
    var cursor = start
    var totalBuffers = 0
    var totalSamples = 0
    var attempts = 0

    while CMTimeCompare(cursor, end) < 0 {
      if !input.isReadyForMoreMediaData {
        if attempts >= maxSpinAttempts { break }
        attempts += 1
        Thread.sleep(forTimeInterval: spinInterval)
        continue
      }
      let (buffers, samples) = fillGap(
        from: cursor,
        to: end,
        channelCount: channelCount,
        sampleRate: sampleRate,
        input: input
      )
      if samples == 0 {
        if attempts >= maxSpinAttempts { break }
        attempts += 1
        Thread.sleep(forTimeInterval: spinInterval)
        continue
      }
      attempts = 0
      totalBuffers += buffers
      totalSamples += samples
      cursor = CMTimeAdd(
        cursor,
        CMTime(value: Int64(samples), timescale: Int32(sampleRate))
      )
    }
    return (totalBuffers, totalSamples)
  }

  nonisolated static func resampleToMono48k(
    _ buffer: AVAudioPCMBuffer,
    sourceRate: Double
  ) -> AVAudioPCMBuffer? {
    guard let inData = buffer.floatChannelData?[0] else { return nil }
    let inFrames = Int(buffer.frameLength)
    let inChannels = Int(buffer.format.channelCount)
    let isInterleaved = buffer.format.isInterleaved

    let needsResample = sourceRate != writerSampleRate
    let ratio = needsResample ? writerSampleRate / sourceRate : 1.0
    let outFrames = needsResample ? Int(ceil(Double(inFrames) * ratio)) : inFrames

    guard
      let monoBuffer = AVAudioPCMBuffer(
        pcmFormat: monoFormat48k,
        frameCapacity: AVAudioFrameCount(outFrames)
      ),
      let outData = monoBuffer.floatChannelData?[0]
    else { return nil }

    if inChannels >= 2 {
      let rightData = isInterleaved ? nil : buffer.floatChannelData?[1]
      guard isInterleaved || rightData != nil else { return nil }

      let monoSample: (Int) -> Float = { index in
        if isInterleaved {
          return (inData[index * 2] + inData[index * 2 + 1]) * 0.5
        }
        return (inData[index] + rightData![index]) * 0.5
      }

      if needsResample {
        for i in 0..<outFrames {
          let srcIdx = Double(i) / ratio
          let lo = Int(srcIdx)
          let hi = min(lo + 1, inFrames - 1)
          let frac = Float(srcIdx - Double(lo))
          let loMono = monoSample(lo)
          let hiMono = monoSample(hi)
          outData[i] = loMono * (1 - frac) + hiMono * frac
        }
      } else {
        for i in 0..<inFrames {
          outData[i] = monoSample(i)
        }
      }
    } else {
      if needsResample {
        for i in 0..<outFrames {
          let srcIdx = Double(i) / ratio
          let lo = Int(srcIdx)
          let hi = min(lo + 1, inFrames - 1)
          let frac = Float(srcIdx - Double(lo))
          outData[i] = inData[lo] * (1 - frac) + inData[hi] * frac
        }
      } else {
        memcpy(outData, inData, inFrames * MemoryLayout<Float>.size)
      }
    }
    monoBuffer.frameLength = AVAudioFrameCount(outFrames)
    return monoBuffer
  }

  nonisolated static func makeSilentSampleBuffer(
    channelCount: Int,
    sampleCount: Int,
    sampleRate: Double,
    presentationTimeStamp: CMTime
  ) -> CMSampleBuffer? {
    let bytesPerSample = MemoryLayout<Float>.size * channelCount
    let dataSize = sampleCount * bytesPerSample

    var asbd = AudioStreamBasicDescription(
      mSampleRate: sampleRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
      mBytesPerPacket: UInt32(bytesPerSample),
      mFramesPerPacket: 1,
      mBytesPerFrame: UInt32(bytesPerSample),
      mChannelsPerFrame: UInt32(channelCount),
      mBitsPerChannel: 32,
      mReserved: 0
    )
    var formatDescription: CMFormatDescription?
    guard
      CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        asbd: &asbd,
        layoutSize: 0,
        layout: nil,
        magicCookieSize: 0,
        magicCookie: nil,
        extensions: nil,
        formatDescriptionOut: &formatDescription
      ) == noErr,
      let formatDescription
    else { return nil }

    var blockBuffer: CMBlockBuffer?
    guard
      CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,
        blockLength: dataSize,
        blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: dataSize,
        flags: kCMBlockBufferAssureMemoryNowFlag,
        blockBufferOut: &blockBuffer
      ) == noErr,
      let blockBuffer
    else { return nil }

    guard
      CMBlockBufferFillDataBytes(
        with: 0,
        blockBuffer: blockBuffer,
        offsetIntoDestination: 0,
        dataLength: dataSize
      ) == noErr
    else { return nil }

    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: Int32(sampleRate)),
      presentationTimeStamp: presentationTimeStamp,
      decodeTimeStamp: .invalid
    )
    var sampleSize = bytesPerSample
    var sampleBuffer: CMSampleBuffer?
    guard
      CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault,
        dataBuffer: blockBuffer,
        formatDescription: formatDescription,
        sampleCount: sampleCount,
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleSizeEntryCount: 1,
        sampleSizeArray: &sampleSize,
        sampleBufferOut: &sampleBuffer
      ) == noErr
    else { return nil }

    return sampleBuffer
  }
}
