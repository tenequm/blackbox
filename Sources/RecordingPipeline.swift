@preconcurrency import AVFoundation
import Accelerate
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

  /// +20 dB makeup gain for mic buffers in a voice-processing layout (>2ch).
  /// The VP raw pathway bypasses the device AGC; measured deficit vs the
  /// normal 1ch pathway was ~23 dB (FaceTime, built-in mic, macOS 26.1).
  nonisolated static let voiceProcessingMakeupGain: Float = 10

  nonisolated let bundleID: String?
  nonisolated let appName: String
  nonisolated let micEnabled: Bool
  nonisolated let saveDirectory: URL
  nonisolated let titlePrefix: String
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
  nonisolated(unsafe) private var recordingDirectory: URL?
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
    titlePrefix: String = "",
    alignmentMode: SessionAlignmentMode,
    onFailure: (@Sendable (RecorderFailure) -> Void)? = nil,
    onAudioLevel: (@Sendable (Float) -> Void)? = nil,
    armSessionStartTimeout: (@Sendable () -> Void)? = nil
  ) {
    self.bundleID = bundleID
    self.appName = appName
    self.micEnabled = micEnabled
    self.saveDirectory = saveDirectory
    self.titlePrefix = titlePrefix
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

    // Self-clean on any partial-init throw: metadata.save / AVAssetWriter
    // init can fail with `dirURL` already on disk but `recordingDirectory` never
    // set. Without this, pipeline.stop() reads it as nil and leaves an
    // orphan directory in the user's recordings folder.
    do {
      let audioURL = dirURL.appendingPathComponent(RecordingStore.audioName)
      Log.info(Log.recorder, "recorder", "writing to \(dirName)/\(RecordingStore.audioName)")

      let metadata = RecordingMetadata(
        title: titlePrefix + appName,
        createdAt: now,
        appName: appName,
        speakers: [:],
        perAppBundleID: bundleID,
        perAppName: nil,
        trackCount: 1 + (micEnabled ? 1 : 0)
      )
      try metadata.save(in: dirURL)

      // v0.6.0 parity: system track is stereo 128 kbps AAC so SCStream buffers
      // can be appended directly. Mic track is mono 64 kbps AAC - the mic path
      // resamples/downmixes to mono via `resampleToMono48k` before append.
      let systemSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: Self.writerSampleRate,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 128_000,
      ]
      let micSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: Self.writerSampleRate,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 64_000,
      ]

      let newWriter = try AVAssetWriter(url: audioURL, fileType: .m4a)
      newWriter.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)

      let systemInput = AVAssetWriterInput(mediaType: .audio, outputSettings: systemSettings)
      systemInput.expectsMediaDataInRealTime = true
      newWriter.add(systemInput)

      var newMicInput: AVAssetWriterInput?
      if micEnabled {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: micSettings)
        input.expectsMediaDataInRealTime = true
        newWriter.add(input)
        newMicInput = input
      }

      guard newWriter.startWriting() else {
        let err = newWriter.error
        Log.error(
          Log.recorder, "recorder",
          "writer startWriting failed: \(err?.localizedDescription ?? "unknown")")
        // Explicit cleanup before throwing so the outer catch's removeItem
        // is a no-op (try? on already-removed dir).
        try? FileManager.default.removeItem(at: dirURL)
        throw err ?? RecorderError.writerFailed
      }

      writer = newWriter
      systemTrack = TrackState(input: systemInput)
      micTrack = TrackState(input: newMicInput)
      recordingDirectory = dirURL
      sessionStarted = false
      sessionStartTime = .invalid
      sessionPending = true
      firstSampleWallClock = nil
      stopped = false
      writerFailureReported = false
      diagnostics = RecordingDiagnostics()
    } catch {
      try? FileManager.default.removeItem(at: dirURL)
      throw error
    }
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

  /// Finalizes the writer and returns the output URL.
  ///
  /// Intentionally `nonisolated` because the caller (`AudioRecorder.stop`) drains
  /// the pipeline before invoking this: the SCStream is stopped and the
  /// AVAudioEngine mic tap is removed. After those teardown steps, no new
  /// buffers can enqueue onto audioQueue, so this method has no work to
  /// serialize against.
  ///
  /// Do not call while any buffer source is still live - the `nonisolated(unsafe)`
  /// state inside the pipeline assumes all writes happen on audioQueue.
  ///
  /// Returns the recording *directory*, not the audio file inside it. Every
  /// consumer of a saved recording works in directories - the file names are
  /// `RecordingStore`'s business - so this hands back the directory and lets
  /// them ask `RecordingStore.audioURL(in:)` for the audio.
  @discardableResult
  nonisolated func stop() async -> URL? {
    stopped = true

    let finalEndTime = [systemTrack.nextExpected, micTrack.nextExpected]
      .filter(\.isValid)
      .max { $0.seconds < $1.seconds }

    if let finalEndTime {
      padTailIfNeeded(for: .mic, to: finalEndTime)
    }

    systemTrack.input?.markAsFinished()
    micTrack.input?.markAsFinished()

    let wasStarted = sessionStarted
    let capturedWriter = writer
    let capturedDirectory = recordingDirectory

    systemTrack = TrackState()
    micTrack = TrackState()
    writer = nil
    recordingDirectory = nil
    sessionStarted = false
    sessionStartTime = .invalid
    sessionPending = true
    firstSampleWallClock = nil

    guard let capturedWriter else { return nil }
    guard wasStarted else {
      capturedWriter.cancelWriting()
      if let capturedDirectory { try? FileManager.default.removeItem(at: capturedDirectory) }
      return nil
    }

    // `finishWriting` is awaited to completion and is never cancelled. An
    // earlier version raced it against a 5s timer that called `cancelWriting`,
    // on the theory that the result would be a truncated file. It is not:
    // AVAssetWriter.h is explicit that "if an output file was created by the
    // receiver during the writing process, -cancelWriting will delete the
    // file." Finalizing a long two-track recording writes the sample tables
    // for hours of audio, so exceeding five seconds on a loaded or nearly-full
    // disk is ordinary - and the recording was being deleted and then reported
    // as saved, because `.cancelled` counted as success below.
    //
    // Nothing is lost by waiting instead: `movieFragmentInterval` (set in
    // `start`) means even a hard kill leaves a playable file. A slow finish is
    // logged so it is visible without being fatal.
    let finishStarted = ContinuousClock.now
    await capturedWriter.finishWriting()
    let finishDuration = ContinuousClock.now - finishStarted
    if finishDuration > .seconds(5) {
      Log.info(
        Log.recorder, "recorder",
        "finishWriting took \(String(format: "%.1fs", Double(finishDuration.components.seconds))) - slow disk or a long recording"
      )
    }

    if capturedWriter.status == .failed {
      Log.error(
        Log.recorder, "recorder",
        "writer failed: \(capturedWriter.error?.localizedDescription ?? "unknown")")
      // Deliberately still returned when something reached disk. Fragment
      // headers make a partial file playable, and handing the user a short
      // recording beats telling them a call they just had does not exist.
      if let capturedDirectory, RecordingStore.audioURL(in: capturedDirectory) != nil {
        return capturedDirectory
      }
      return nil
    }

    return capturedWriter.status == .completed ? capturedDirectory : nil
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

    // Silence gap fill runs on the mic track only. SCStream buffers are
    // appended directly (v0.6.0 parity); generating format-matched stereo
    // silence on the fly is brittle and v0.6.0 shipped without it.
    if track == .mic {
      if !nextExpected.isValid, sessionStartTime.isValid,
        let input = self[track].input,
        CMTimeCompare(pts, sessionStartTime) > 0
      {
        let leadSeconds = CMTimeGetSeconds(pts - sessionStartTime)
        if leadSeconds > 0.001 {
          let (leadingBuffers, _) = Self.fillGapFully(
            from: sessionStartTime,
            to: pts,
            channelCount: 1,
            sampleRate: Self.writerSampleRate,
            input: input
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
      Log.warning(Log.recorder, "recorder", "\(track.rawValue) append failed for \(appName)")
      reportWriterFailureIfNeeded()
    }
  }

  nonisolated private func padTailIfNeeded(for track: RecordingTrackKind, to finalEndTime: CMTime) {
    // Tail padding runs on the mic track only - same rationale as the
    // gap-fill guard in appendSample.
    guard track == .mic else { return }
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

    let samplePtr = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: Float.self)
    var meanSquare: Float = 0
    vDSP_measqv(samplePtr, 1, &meanSquare, vDSP_Length(floatCount))
    let rms = meanSquare.squareRoot()
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

  /// Drives `fillGap` in a loop until `end` is reached or the writer input
  /// refuses further samples. Never blocks `audioQueue`: if
  /// `isReadyForMoreMediaData` is false mid-loop, breaks immediately per D8
  /// ("Safety: never risk the recording for sync", `docs/specification.md`).
  ///
  /// On early break, the leftover gap is accepted. Leading-silence callers
  /// reattempt on the next `appendSample` invocation via `fillGap`. Tail
  /// padding from `stop()` accepts the residual as desync rather than
  /// re-queuing work on audioQueue.
  nonisolated static func fillGapFully(
    from start: CMTime,
    to end: CMTime,
    channelCount: Int,
    sampleRate: Double,
    input: AVAssetWriterInput
  ) -> (buffers: Int, samples: Int) {
    var cursor = start
    var totalBuffers = 0
    var totalSamples = 0

    while CMTimeCompare(cursor, end) < 0 {
      if !input.isReadyForMoreMediaData { break }
      let (buffers, samples) = fillGap(
        from: cursor,
        to: end,
        channelCount: channelCount,
        sampleRate: sampleRate,
        input: input
      )
      if samples == 0 { break }
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

    // Mono extractor per frame. Stereo averages L/R. More than 2 channels is
    // a voice-processing layout (e.g. FaceTime active on the same input
    // device): channel 0 is the mic, the rest are AEC metadata channels that
    // must not be averaged in (they attenuate the mic toward silence). The
    // VP raw pathway also bypasses the device's AGC (~20+ dB below the
    // normal 1ch pathway, measured), so those buffers get makeup gain with
    // a hard clamp.
    let mono: (Int) -> Float
    if inChannels == 2 {
      if isInterleaved {
        mono = { (inData[$0 * 2] + inData[$0 * 2 + 1]) * 0.5 }
      } else {
        guard let rightData = buffer.floatChannelData?[1] else { return nil }
        mono = { (inData[$0] + rightData[$0]) * 0.5 }
      }
    } else if inChannels > 2 {
      let stride = isInterleaved ? inChannels : 1
      mono = { min(max(inData[$0 * stride] * voiceProcessingMakeupGain, -1), 1) }
    } else {
      mono = { inData[$0] }
    }

    if needsResample {
      for i in 0..<outFrames {
        let srcIdx = Double(i) / ratio
        let lo = Int(srcIdx)
        let hi = min(lo + 1, inFrames - 1)
        let frac = Float(srcIdx - Double(lo))
        outData[i] = mono(lo) * (1 - frac) + mono(hi) * frac
      }
    } else if inChannels == 1 {
      memcpy(outData, inData, inFrames * MemoryLayout<Float>.size)
    } else {
      for i in 0..<inFrames {
        outData[i] = mono(i)
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
