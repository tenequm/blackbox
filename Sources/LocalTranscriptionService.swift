@preconcurrency import AVFoundation
import CoreMedia
import FluidAudio

/// On-device transcription using FluidAudio (Parakeet TDT v3 ASR + offline diarization).
/// Extracts dual tracks from the recording, transcribes and diarizes each independently,
/// then merges with speaker attribution via temporal overlap matching.
enum LocalTranscriptionService {

  /// Whether ASR and diarizer model files have been downloaded to disk.
  nonisolated static var modelsReady: Bool {
    UserDefaults.standard.bool(forKey: "localTranscriptionModelsReady")
  }

  // MARK: - Public API

  /// Transcribe a recording and return the document. Status updates are sent via
  /// `onStatus` which is `@Sendable` - callers must dispatch to MainActor themselves.
  static func transcribe(
    recordingDirectory: URL,
    onStatus: @escaping @Sendable (TranscriptionStatus) -> Void
  ) async throws -> TranscriptDocument {
    let processedURL = recordingDirectory.appendingPathComponent("audio-processed.m4a")
    let originalURL = recordingDirectory.appendingPathComponent("audio.m4a")
    let audioURL =
      FileManager.default.fileExists(atPath: processedURL.path) ? processedURL : originalURL

    let doc = try await Task.detached {
      try await Self.run(audioURL: audioURL, onStatus: onStatus)
    }.value

    onStatus(.completed)
    return doc
  }

  /// Convenience: transcribe and save to disk as `transcript-local.json`.
  static func transcribeAndSave(
    recordingDirectory: URL,
    onStatus: @escaping @Sendable (TranscriptionStatus) -> Void = { _ in }
  ) async throws {
    let doc = try await transcribe(
      recordingDirectory: recordingDirectory, onStatus: onStatus)
    try doc.save(for: recordingDirectory, provider: .local)
  }

  /// Download and prepare all models (ASR + diarizer). Call from Settings UI.
  static func prepareModels(
    onStatus: @escaping @Sendable (TranscriptionStatus) -> Void
  ) async throws {
    onStatus(.preparing)
    try await Task.detached {
      try await Self.downloadAllModels()
    }.value
    onStatus(.completed)
  }

  // MARK: - Core Pipeline (runs off main actor)

  nonisolated private static func run(
    audioURL: URL,
    onStatus: @Sendable (TranscriptionStatus) -> Void
  ) async throws -> TranscriptDocument {
    try Task.checkCancellation()

    // 1. Load models (fast from cache on subsequent calls)
    onStatus(.preparing)
    let asrModels = try await downloadASRModels()
    let diarizerManager = OfflineDiarizerManager()
    try await diarizerManager.prepareModels()
    UserDefaults.standard.set(true, forKey: "localTranscriptionModelsReady")

    try Task.checkCancellation()

    // 2. Extract tracks
    onStatus(.transcribing)
    let (systemSamples, micSamples) = try await extractTracks(from: audioURL)

    Log.info(
      Log.transcription, "local",
      "extracted tracks: system=\(systemSamples.count) samples"
        + (micSamples != nil ? ", mic=\(micSamples!.count) samples" : " (single-track)"))

    try Task.checkCancellation()

    // 3. ASR
    let asrManager = AsrManager()
    try await asrManager.initialize(models: asrModels)

    let systemASR = try await asrManager.transcribe(systemSamples, source: .system)
    Log.info(
      Log.transcription, "local",
      "system ASR: \(systemASR.text.prefix(80))... (\(String(format: "%.0f", systemASR.rtfx))x realtime)"
    )

    try Task.checkCancellation()

    var micASR: ASRResult?
    if let micSamples {
      micASR = try await asrManager.transcribe(micSamples, source: .microphone)
      Log.info(
        Log.transcription, "local",
        "mic ASR: \(micASR!.text.prefix(80))... (\(String(format: "%.0f", micASR!.rtfx))x realtime)"
      )
    }

    try Task.checkCancellation()

    // 4. Diarize (graceful degradation - transcript still works without diarization)
    var systemDiarization: DiarizationResult?
    var micDiarization: DiarizationResult?

    do {
      systemDiarization = try await diarizerManager.process(audio: systemSamples)
      Log.info(
        Log.transcription, "local",
        "system diarization: \(systemDiarization!.segments.count) segments")

      if let micSamples {
        try Task.checkCancellation()
        micDiarization = try await diarizerManager.process(audio: micSamples)
        Log.info(
          Log.transcription, "local",
          "mic diarization: \(micDiarization!.segments.count) segments")
      }
    } catch {
      Log.error(Log.transcription, "local", "diarization failed, proceeding without: \(error)")
    }

    // 5. Assign speakers to ASR segments via temporal overlap
    let systemSegments = labelSegments(asr: systemASR, diarization: systemDiarization)
    let micSegments = micASR != nil ? labelSegments(asr: micASR!, diarization: micDiarization) : nil

    // 6. Merge into document
    let language = systemASR.ctcDetectedTerms?.first

    return mergeIntoDocument(
      systemSegments: systemSegments,
      micSegments: micSegments,
      language: language
    )
  }

  // MARK: - Model Loading

  /// Downloads ASR models only. Diarizer models are prepared in `run()` where
  /// the `OfflineDiarizerManager` instance is actually used.
  @discardableResult
  nonisolated private static func downloadASRModels() async throws -> AsrModels {
    let asrModels = try await AsrModels.downloadAndLoad(version: .v3)
    Log.info(Log.transcription, "local", "ASR models ready")
    return asrModels
  }

  /// Downloads both ASR and diarizer models (for Settings pre-download).
  nonisolated private static func downloadAllModels() async throws {
    _ = try await AsrModels.downloadAndLoad(version: .v3)
    let diarizerManager = OfflineDiarizerManager()
    try await diarizerManager.prepareModels()
    UserDefaults.standard.set(true, forKey: "localTranscriptionModelsReady")
    Log.info(Log.transcription, "local", "all models ready")
  }

  // MARK: - Track Extraction

  nonisolated private static func extractTracks(
    from url: URL
  ) async throws -> (system: [Float], mic: [Float]?) {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .audio)

    guard !tracks.isEmpty else {
      throw LocalTranscriptionError.noAudioTracks
    }

    let pcmSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: 16000 as Double,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]

    let duration = try await asset.load(.duration).seconds
    let expectedSamples = Int(duration * 16000)

    let systemSamples = try readTrack(
      tracks[0], asset: asset, settings: pcmSettings, reserveCount: expectedSamples)
    let micSamples =
      tracks.count >= 2
      ? try readTrack(
        tracks[1], asset: asset, settings: pcmSettings, reserveCount: expectedSamples) : nil

    return (system: systemSamples, mic: micSamples)
  }

  nonisolated private static func readTrack(
    _ track: AVAssetTrack, asset: AVURLAsset, settings: [String: Any],
    reserveCount: Int
  ) throws -> [Float] {
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
    output.alwaysCopiesSampleData = false
    reader.add(output)

    guard reader.startReading() else {
      throw LocalTranscriptionError.trackReadFailed(
        reader.error?.localizedDescription ?? "unknown")
    }

    var samples: [Float] = []
    samples.reserveCapacity(reserveCount)
    while let sampleBuffer = output.copyNextSampleBuffer() {
      guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
      let length = CMBlockBufferGetDataLength(blockBuffer)
      let floatCount = length / MemoryLayout<Float>.size
      var chunk = [Float](repeating: 0, count: floatCount)
      chunk.withUnsafeMutableBufferPointer { ptr in
        guard let base = ptr.baseAddress else { return }
        _ = CMBlockBufferCopyDataBytes(
          blockBuffer, atOffset: 0, dataLength: length, destination: base)
      }
      samples.append(contentsOf: chunk)
    }

    return samples
  }

  // MARK: - Speaker Assignment (Temporal Overlap Matching)

  private struct LabeledSegment {
    let speakerId: String
    let startTime: Double
    let text: String
  }

  /// Assign speaker labels to ASR tokens by finding the diarization segment
  /// with maximum temporal overlap. Falls back to nearest segment by gap distance.
  nonisolated private static func labelSegments(
    asr: ASRResult, diarization: DiarizationResult?
  ) -> [LabeledSegment] {
    // No diarization or no token timings - entire text as one segment
    guard let timings = asr.tokenTimings, !timings.isEmpty,
      let diarization, !diarization.segments.isEmpty
    else {
      let speaker =
        diarization?.segments
        .max(by: { $0.durationSeconds < $1.durationSeconds })?.speakerId ?? "SPEAKER_0"
      return [LabeledSegment(speakerId: speaker, startTime: 0, text: asr.text)]
    }

    // For each token, find best matching diarization speaker
    var labeledTokens: [(speakerId: String, timing: TokenTiming)] = []

    for token in timings {
      let tokenStart = Float(token.startTime)
      let tokenEnd = Float(token.endTime)

      var bestSpeaker: String?
      var bestOverlap: Float = 0

      for seg in diarization.segments {
        let overlap = max(
          0, min(tokenEnd, seg.endTimeSeconds) - max(tokenStart, seg.startTimeSeconds))
        if overlap > bestOverlap {
          bestOverlap = overlap
          bestSpeaker = seg.speakerId
        }
      }

      // Fallback: nearest diarization segment by gap distance
      if bestSpeaker == nil {
        var nearestGap: Float = .infinity
        for seg in diarization.segments {
          let gap: Float
          if tokenEnd <= seg.startTimeSeconds {
            gap = seg.startTimeSeconds - tokenEnd
          } else if tokenStart >= seg.endTimeSeconds {
            gap = tokenStart - seg.endTimeSeconds
          } else {
            gap = 0
          }
          if gap < nearestGap {
            nearestGap = gap
            bestSpeaker = seg.speakerId
          }
        }
      }

      labeledTokens.append((bestSpeaker ?? "SPEAKER_0", token))
    }

    // Group consecutive same-speaker tokens into segments
    var segments: [LabeledSegment] = []
    var currentSpeaker: String?
    var currentText = ""
    var currentStart: Double = 0

    for (speaker, token) in labeledTokens {
      if speaker != currentSpeaker {
        if let s = currentSpeaker,
          !currentText.trimmingCharacters(in: .whitespaces).isEmpty
        {
          segments.append(
            LabeledSegment(
              speakerId: s, startTime: currentStart,
              text: currentText.trimmingCharacters(in: .whitespaces)))
        }
        currentSpeaker = speaker
        currentText = ""
        currentStart = token.startTime
      }
      currentText += token.token
    }

    if let s = currentSpeaker, !currentText.trimmingCharacters(in: .whitespaces).isEmpty {
      segments.append(
        LabeledSegment(
          speakerId: s, startTime: currentStart,
          text: currentText.trimmingCharacters(in: .whitespaces)))
    }

    return segments
  }

  // MARK: - Merge Dual-Track Results

  /// Merge labeled segments from system (remote) and mic (local) tracks into a
  /// TranscriptDocument with sequential integer speaker IDs and default names.
  nonisolated private static func mergeIntoDocument(
    systemSegments: [LabeledSegment],
    micSegments: [LabeledSegment]?,
    language: String?
  ) -> TranscriptDocument {
    // Collect unique speaker IDs per track
    var micSpeakerIds: [String] = []
    if let micSegs = micSegments {
      var seen = Set<String>()
      for seg in micSegs where seen.insert(seg.speakerId).inserted {
        micSpeakerIds.append(seg.speakerId)
      }
    }

    var remoteSpeakerIds: [String] = []
    var seenRemote = Set<String>()
    for seg in systemSegments where seenRemote.insert(seg.speakerId).inserted {
      remoteSpeakerIds.append(seg.speakerId)
    }

    // Map to sequential integers: mic speakers first, then remote
    var speakerMap: [String: Int] = [:]
    var speakerNames: [String: String] = [:]
    var nextId = 0

    for id in micSpeakerIds {
      speakerMap["M_\(id)"] = nextId
      speakerNames[String(nextId)] =
        micSpeakerIds.count == 1 ? "You" : "Local \(nextId + 1)"
      nextId += 1
    }

    for id in remoteSpeakerIds {
      speakerMap["R_\(id)"] = nextId
      speakerNames[String(nextId)] = "Speaker \(nextId + 1)"
      nextId += 1
    }

    // Convert to TranscriptSegments
    var allSegments: [TranscriptSegment] = []

    if let micSegs = micSegments {
      for seg in micSegs {
        allSegments.append(
          TranscriptSegment(
            speaker: speakerMap["M_\(seg.speakerId)"] ?? 0,
            time: seg.startTime,
            text: seg.text))
      }
    }

    for seg in systemSegments {
      allSegments.append(
        TranscriptSegment(
          speaker: speakerMap["R_\(seg.speakerId)"] ?? 0,
          time: seg.startTime,
          text: seg.text))
    }

    // Sort by time
    allSegments.sort { $0.time < $1.time }

    // Single-track: no M_/R_ prefixes were used, simplify speaker names
    if micSegments == nil {
      speakerNames = [:]
      for (i, id) in remoteSpeakerIds.enumerated() {
        speakerMap["R_\(id)"] = i
        speakerNames[String(i)] = "Speaker \(i + 1)"
      }
      // Re-map segments with corrected IDs
      allSegments = systemSegments.map { seg in
        TranscriptSegment(
          speaker: speakerMap["R_\(seg.speakerId)"] ?? 0,
          time: seg.startTime,
          text: seg.text)
      }
    }

    return TranscriptDocument(
      segments: allSegments,
      language: language,
      createdAt: Date(),
      speakers: speakerNames
    )
  }
}

// MARK: - Errors

nonisolated enum LocalTranscriptionError: Error, LocalizedError, Sendable {
  case noAudioTracks
  case trackReadFailed(String)

  var errorDescription: String? {
    switch self {
    case .noAudioTracks: "No audio tracks found in recording"
    case .trackReadFailed(let msg): "Failed to read audio track: \(msg)"
    }
  }
}
