import AVFoundation
import Foundation

// MARK: - Data Models

nonisolated struct RecordingMetadata: Codable, Sendable {
  var title: String
  var createdAt: Date
  var appName: String
  var speakers: [String: String]
  var perAppBundleID: String?
  var perAppName: String?
  var trackCount: Int?

  static let fileName = "metadata.json"

  init(
    title: String, createdAt: Date, appName: String, speakers: [String: String],
    perAppBundleID: String? = nil, perAppName: String? = nil, trackCount: Int? = nil
  ) {
    self.title = title
    self.createdAt = createdAt
    self.appName = appName
    self.speakers = speakers
    self.perAppBundleID = perAppBundleID
    self.perAppName = perAppName
    self.trackCount = trackCount
  }

  /// Hand-written for the same reason `TranscriptionJob`'s is: the synthesized
  /// decoder throws on a missing key rather than falling back to the property's
  /// default, and `load` swallows that with `try?`. Adding one non-optional
  /// field would therefore make every metadata file a previous build wrote
  /// undecodable at once - and the three rename paths rebuild a fresh record
  /// from `load(...) ?? RecordingMetadata(...)` and write it back, so a single
  /// unreadable decode plus one rename permanently loses the title, the date and
  /// every speaker name. Every key is optional here so the format stays
  /// additive.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
    createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    appName = try container.decodeIfPresent(String.self, forKey: .appName) ?? ""
    speakers = try container.decodeIfPresent([String: String].self, forKey: .speakers) ?? [:]
    perAppBundleID = try container.decodeIfPresent(String.self, forKey: .perAppBundleID)
    perAppName = try container.decodeIfPresent(String.self, forKey: .perAppName)
    trackCount = try container.decodeIfPresent(Int.self, forKey: .trackCount)
  }

  static func load(in directory: URL) -> RecordingMetadata? {
    let url = directory.appendingPathComponent(fileName)
    guard let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(RecordingMetadata.self, from: data)
  }

  func save(in directory: URL) throws {
    let url = directory.appendingPathComponent(Self.fileName)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(self)
    try data.write(to: url, options: .atomic)
  }
}

/// Where a recording's files live and how to find them. Centralised because
/// two rules here are easy to get subtly wrong in a copy: which of the two
/// audio files is the current one, and how to enumerate recording directories.
nonisolated enum RecordingStore {
  static let audioName = "audio.m4a"
  static let processedAudioName = "audio-processed.m4a"

  /// The echo-cancelled output when the user has run AEC, otherwise the raw
  /// capture. Nil when the directory holds neither.
  static func audioURL(in recordingDirectory: URL) -> URL? {
    let processed = recordingDirectory.appendingPathComponent(processedAudioName)
    if isUsable(processed) { return processed }
    let raw = recordingDirectory.appendingPathComponent(audioName)
    return isUsable(raw) ? raw : nil
  }

  /// Exists *and* has bytes. A killed echo-cancellation run used to leave a
  /// zero-byte `audio-processed.m4a`, and because this method prefers the
  /// processed file, that empty file silently became the playback, export and
  /// transcription source - so a recording whose audio was perfectly intact
  /// reported "Could not load audio: Cannot Open".
  static func isUsable(_ url: URL) -> Bool {
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
    return size > 0
  }

  /// Enumerates by name rather than with `contentsOfDirectory(at:)`, which
  /// resolves symlinks in its base and hands back a different spelling of the
  /// same path than the recorder produces. Transcription status is keyed by
  /// path, so the two spellings have to agree.
  /// Dotfiles are filtered here because the path-based enumeration has no
  /// equivalent of `.skipsHiddenFiles`, and without it every scan stats
  /// `.DS_Store` looking for a recording inside it.
  static func directories(in saveDirectory: URL) -> [URL] {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: saveDirectory.path)
    else { return [] }
    return
      names
      .filter { !$0.hasPrefix(".") }
      .map { saveDirectory.appendingPathComponent($0, isDirectory: true) }
  }
}

nonisolated struct ExportedSegment: Codable, Sendable {
  var speaker: String
  var time: String
  var text: String
}

nonisolated struct TranscriptDocument: Codable, Sendable {
  var segments: [TranscriptSegment]
  var language: String?
  var createdAt: Date
  /// Which service and model produced this. Optional so transcripts written
  /// before provenance existed still decode, and so a later provider picker has
  /// something to label them with.
  var provider: String?
  var model: String?

  init(
    segments: [TranscriptSegment], language: String? = nil, createdAt: Date,
    provider: String? = nil, model: String? = nil
  ) {
    self.segments = segments
    self.language = language
    self.createdAt = createdAt
    self.provider = provider
    self.model = model
  }

  /// Hand-written for the same reason as `RecordingMetadata`'s. Here the cost of
  /// an undecodable file is a paid-for transcript vanishing from the detail
  /// view, the user pressing Transcribe, and the intact file being overwritten
  /// by a re-billed one.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    segments = try container.decodeIfPresent([TranscriptSegment].self, forKey: .segments) ?? []
    language = try container.decodeIfPresent(String.self, forKey: .language)
    createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    provider = try container.decodeIfPresent(String.self, forKey: .provider)
    model = try container.decodeIfPresent(String.self, forKey: .model)
  }

  nonisolated static func sidecarURL(for recordingURL: URL) -> URL {
    recordingURL.appendingPathComponent("transcript.json")
  }

  nonisolated static func load(for recordingURL: URL) -> TranscriptDocument? {
    let url = sidecarURL(for: recordingURL)
    guard let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(TranscriptDocument.self, from: data)
  }

  func save(for recordingURL: URL) throws {
    let url = Self.sidecarURL(for: recordingURL)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(self)
    try data.write(to: url, options: .atomic)
  }
}

nonisolated struct TranscriptSegment: Codable, Identifiable, Sendable {
  var id: UUID
  var speaker: Int
  var time: Double
  var text: String

  init(speaker: Int, time: Double, text: String) {
    self.id = UUID()
    self.speaker = speaker
    self.time = time
    self.text = text
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
    self.speaker = try container.decode(Int.self, forKey: .speaker)
    self.time = try container.decode(Double.self, forKey: .time)
    self.text = try container.decode(String.self, forKey: .text)
  }
}

/// Which half of `upload` is running. The two are reported separately because
/// they fail and stall for different reasons, and because on a long call the
/// local re-encode is the longer of the two.
nonisolated enum TranscriptionUploadPhase: Sendable {
  case mixing(Double)
  case uploading(Double)
}

/// Reports bytes-sent for a single upload. `URLSession.shared` has no delegate
/// of its own, so this is attached per task rather than per session.
/// `@unchecked Sendable` because the callback is the only state and it is
/// immutable; libdispatch delivers the delegate calls on the session queue.
nonisolated final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate,
  @unchecked Sendable
{
  private let onFraction: @Sendable (Double) -> Void

  init(onFraction: @escaping @Sendable (Double) -> Void) {
    self.onFraction = onFraction
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
    totalBytesExpectedToSend: Int64
  ) {
    guard totalBytesExpectedToSend > 0 else { return }
    onFraction(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
  }
}

/// Every stage the user can be waiting through gets its own case. They used to
/// collapse into three, so a job held behind a recording, a job third in line,
/// and a job an hour into offline retries all read "Queued for transcription"
/// - which tells the user nothing about whether the wait is theirs to fix.
nonisolated enum TranscriptionStatus: Equatable, Sendable {
  case idle
  /// Enqueued and not yet started, waiting for an upload slot, or submitted to
  /// Soniox and waiting for it to begin.
  case queued
  /// Re-encoding the two tracks into one file. Local, slow on a long call, and
  /// entirely invisible before it had its own case.
  case mixing(fraction: Double)
  case uploading(fraction: Double)
  case transcribing
  /// Network is unreachable; retrying without spending an attempt.
  case offline
  /// A recoverable failure is being retried, with which attempt this is.
  case retrying(attempt: Int, of: Int)
  /// The user asked to stop and the job has not finished unwinding yet.
  case cancelling
  case completed
  case error(String)

  /// True while the job is doing or waiting on work - anything that should show
  /// progress rather than an action button.
  var isActive: Bool {
    switch self {
    case .idle, .completed, .error: false
    default: true
    }
  }

  /// Determinate progress for the stages that can report it, nil for the rest.
  var fraction: Double? {
    switch self {
    case .mixing(let f), .uploading(let f): f
    default: nil
    }
  }
}

nonisolated enum TranscriptionError: Error, LocalizedError, Sendable {
  case uploadFailed(String)
  case transcriptionFailed(String)
  case serverError(Int, String)
  /// 409 `transcription_invalid_state` - the transcript is not retrievable yet.
  /// Retryable: polling and fetching are separate calls, so a job that finishes
  /// between them answers 409 for a moment.
  case notReady(String)
  case balanceExhausted(String)
  case pollTimeout

  var errorDescription: String? {
    switch self {
    case .uploadFailed(let msg): "Upload failed: \(msg)"
    case .transcriptionFailed(let msg): "Transcription failed: \(msg)"
    case .serverError(let code, let msg): "Soniox error \(code): \(msg)"
    case .notReady(let msg): "Transcript not ready: \(msg)"
    case .balanceExhausted(let msg): "Soniox balance or budget exhausted: \(msg)"
    case .pollTimeout: "Transcription timed out"
    }
  }

  /// Whether another pass is worth attempting. Lives with the error rather than
  /// with the caller so adding a case forces the decision here, where the
  /// status codes it came from are documented.
  var isRetryable: Bool {
    switch self {
    case .serverError, .pollTimeout, .notReady: true
    case .uploadFailed, .transcriptionFailed, .balanceExhausted: false
    }
  }
}

// MARK: - Soniox API Client

/// Stage-level transcription API. `TranscriptionCoordinator` drives the state
/// machine, so a job interrupted by quit or a network failure resumes from its
/// persisted stage instead of re-uploading.
///
/// Every requirement is `@concurrent`: under this target's `.defaultIsolation(MainActor.self)`,
/// a `nonisolated` conforming type is *not* enough to get async work off the main
/// thread - the annotation on the requirement is what moves it, for class and
/// actor witnesses alike. Without it, transcript JSON parsing and poll responses
/// are decoded on the main thread.
protocol TranscriptionServicing: Sendable {
  /// Mixes multi-track audio into a single file when needed, uploads it, and
  /// returns the remote file id.
  @concurrent func upload(
    fileURL: URL,
    onProgress: @escaping @Sendable (TranscriptionUploadPhase) -> Void
  ) async throws -> String
  @concurrent func createTranscription(fileId: String, reference: String) async throws -> String
  @concurrent func awaitCompletion(transcriptionId: String) async throws
  @concurrent func fetchTranscript(transcriptionId: String) async throws -> TranscriptDocument
  @concurrent func deleteRemote(transcriptionIds: [String], fileIds: [String]) async
}

nonisolated final class TranscriptionService: TranscriptionServicing {
  static let defaultModel = "stt-async-v5"
  /// Offered in Settings. A free-text field meant a typo became a terminal
  /// failure per recording, discovered one recording at a time and only after
  /// an upload had already been paid for - while "Verify Key" happily reported
  /// success, because it checks the key and not the model.
  static let knownModels = ["stt-async-v5", "stt-async-preview"]
  static let defaultBaseURL = "https://api.soniox.com"
  static let providerName = "soniox"

  private let apiKey: String
  private let model: String
  private let baseURL: String
  private static let mixPrefix = "blackbox-mixed-"
  private static let uploadSuffix = ".multipart"
  private static let pollCeiling = Duration.seconds(30 * 60)
  /// Soniox caps `client_reference_id` at 256 characters.
  private static let referenceLimit = 256
  private static let bodyLogLimit = 512

  /// Falls back to the default when the stored model is blank - the Settings
  /// field is free text, and an empty `model` is rejected by every request.
  static func resolvedModel(_ stored: String?) -> String {
    let trimmed = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? defaultModel : trimmed
  }

  /// The one place that decides whether this process may talk to Soniox at all.
  ///
  /// Under `--ui-test-mode` the answer is never: the smoke suite records real
  /// audio on a developer's machine, so a live-host client there would send
  /// their call audio to a third party and bill them for it. Enforced here
  /// rather than at each call site because a call site is a thing to forget -
  /// every request in this feature is built by an instance of this type or by
  /// `verifyAPIKey`, and both funnel through this check.
  ///
  /// `precondition`, not `assert`: `make bundle` builds release, which is what
  /// the smoke suite launches, and `assert` is compiled out there. Crashing a
  /// test run is the correct failure - loud, immediate, impossible to mistake
  /// for a pass.
  /// The policy, split from the assertion so it can be tested: `isEnabled` is a
  /// launch-time constant, so a test process can never make the assertion fire.
  nonisolated static func egressAllowed(baseURL: String, underTestMode: Bool) -> Bool {
    !underTestMode || baseURL != defaultBaseURL
  }

  nonisolated private static func assertEgressAllowed(_ baseURL: String) {
    precondition(
      egressAllowed(baseURL: baseURL, underTestMode: BlackboxTestMode.isEnabled),
      "refusing to reach the live Soniox API under --ui-test-mode")
  }

  /// `baseURL` is injectable so the contract tests can point the client at a
  /// loopback stub that speaks the documented Soniox wire format.
  init(apiKey: String, model: String = defaultModel, baseURL: String = defaultBaseURL) {
    Self.assertEgressAllowed(baseURL)
    self.apiKey = apiKey
    self.model = model
    self.baseURL = baseURL
  }

  /// Checks a key without spending anything: the file list is the cheapest
  /// authenticated endpoint. Lets Settings tell the user the key is wrong now
  /// rather than through a recording that silently fails to transcribe later.
  @concurrent
  static func verifyAPIKey(_ apiKey: String, baseURL: String = defaultBaseURL) async -> (
    isValid: Bool, message: String?
  ) {
    // Static, so it never passes through `init` - it needs its own check.
    assertEgressAllowed(baseURL)
    guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return (false, "No API key entered.")
    }
    guard let url = URL(string: "\(baseURL)/v1/files") else { return (false, "Invalid URL.") }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 10
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse else { return (false, "No HTTP response.") }
      if (200..<300).contains(http.statusCode) { return (true, nil) }
      let envelope = Self.errorEnvelope(from: data)
      return (false, envelope.message ?? "HTTP \(http.statusCode)")
    } catch {
      return (false, error.localizedDescription)
    }
  }

  /// For dual-track recordings (system audio + mic), tracks are mixed into a
  /// single file first so Soniox can diarize speakers from the combined audio,
  /// producing proper speaker separation and timestamps.
  ///
  /// Every Blackbox recording is dual-track, so the mix always runs - and on a
  /// long call it is the slowest thing here, a full re-encode before a byte
  /// leaves the machine. `onProgress` exists because that used to be minutes of
  /// a spinner captioned "Uploading audio...", which is both the wrong stage
  /// and no way to tell work from a stall.
  @concurrent
  func upload(
    fileURL: URL,
    onProgress: @escaping @Sendable (TranscriptionUploadPhase) -> Void
  ) async throws -> String {
    let asset = AVURLAsset(url: fileURL)
    let tracks = try await asset.loadTracks(withMediaType: .audio)

    guard tracks.count >= 2 else { return try await uploadFile(fileURL, onProgress: onProgress) }

    Log.info(
      Log.transcription, "transcription",
      "dual-track file detected (\(tracks.count) tracks), mixing before transcription")
    let mixedURL = try await Self.mix(asset: asset, tracks: tracks, onProgress: onProgress)
    defer { try? FileManager.default.removeItem(at: mixedURL) }
    return try await uploadFile(mixedURL, onProgress: onProgress)
  }

  // MARK: - Audio Mixing & Export

  /// Takes an already-loaded asset so callers that had to inspect the track
  /// count first do not parse the container a second time.
  @concurrent
  static func mix(
    asset: AVAsset,
    tracks: [AVAssetTrack],
    onProgress: (@Sendable (TranscriptionUploadPhase) -> Void)? = nil
  ) async throws -> URL {
    let composition = AVMutableComposition()
    let duration = try await asset.load(.duration)

    // For 3-track recordings (display-wide + per-app + mic), skip display-wide (track 0)
    // to avoid doubling call audio. Use per-app + mic only.
    let tracksToMix = tracks.count >= 3 ? Array(tracks.dropFirst()) : tracks

    for sourceTrack in tracksToMix {
      guard
        let compositionTrack = composition.addMutableTrack(
          withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
      else { continue }
      try compositionTrack.insertTimeRange(
        CMTimeRange(start: .zero, duration: duration),
        of: sourceTrack,
        at: .zero
      )
    }

    let tempURL =
      FileManager.default.temporaryDirectory
      .appendingPathComponent("\(Self.mixPrefix)\(UUID().uuidString).m4a")

    guard
      let exporter = AVAssetExportSession(
        asset: composition, presetName: AVAssetExportPresetAppleM4A)
    else {
      throw TranscriptionError.transcriptionFailed("could not create export session for mixing")
    }

    do {
      if let onProgress {
        onProgress(.mixing(0))
        // `nonisolated(unsafe)` because `AVAssetExportSession` is not Sendable
        // and both the export and its progress sequence need the same
        // instance. Reading progress while an export runs is what the API is
        // for - `states(updateInterval:)` exists to be consumed concurrently
        // with `export(to:as:)`, and the sequence ends when the export does.
        nonisolated(unsafe) let session = exporter
        async let export: Void = session.export(to: tempURL, as: .m4a)
        for await state in session.states(updateInterval: 0.5) {
          if case .exporting(let progress) = state {
            onProgress(.mixing(progress.fractionCompleted))
          }
        }
        try await export
        onProgress(.mixing(1))
      } else {
        try await exporter.export(to: tempURL, as: .m4a)
      }
    } catch {
      throw TranscriptionError.transcriptionFailed(
        "track mixing failed: \(error.localizedDescription)")
    }

    Log.info(Log.transcription, "transcription", "mixed \(tracks.count) tracks into single file")
    return tempURL
  }

  /// Removes mix and upload scratch files stranded by a quit mid-job. Each is
  /// the full size of a recording, and resume-after-quit makes that a routine
  /// path rather than a crash-only one.
  @concurrent
  static func sweepTemporaryFiles() async {
    let temporaryDirectory = FileManager.default.temporaryDirectory
    guard
      let names = try? FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)
    else { return }
    for name in names
    where name.hasPrefix(Self.mixPrefix) || name.hasSuffix(Self.uploadSuffix) {
      try? FileManager.default.removeItem(at: temporaryDirectory.appendingPathComponent(name))
    }
  }

  /// Exports a single-track M4A copy. Mixes tracks first if multi-track.
  @concurrent
  static func exportM4A(from fileURL: URL, to outputURL: URL) async throws {
    let asset = AVURLAsset(url: fileURL)
    let tracks = try await asset.loadTracks(withMediaType: .audio)

    // NSSavePanel's "Replace" confirmation does not remove the target, and
    // `copyItem` throws on an existing file - so agreeing to replace produced a
    // "file exists" error and left the old file untouched.
    guard tracks.count >= 2 else {
      try? FileManager.default.removeItem(at: outputURL)
      try FileManager.default.copyItem(at: fileURL, to: outputURL)
      return
    }
    // Reuses the already-loaded asset rather than re-parsing the container.
    let mixed = try await mix(asset: asset, tracks: tracks)
    defer { try? FileManager.default.removeItem(at: mixed) }
    try? FileManager.default.removeItem(at: outputURL)
    try FileManager.default.copyItem(at: mixed, to: outputURL)
  }

  // MARK: - Upload

  @concurrent
  private func uploadFile(
    _ fileURL: URL,
    onProgress: (@Sendable (TranscriptionUploadPhase) -> Void)? = nil
  ) async throws -> String {
    let boundary = UUID().uuidString

    // Build multipart body as a temp file to avoid loading entire audio into memory
    let tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString + Self.uploadSuffix)
    defer { try? FileManager.default.removeItem(at: tempURL) }
    try Self.writeMultipartBody(audio: fileURL, boundary: boundary, to: tempURL)

    var request = try makeRequest(.post, "/v1/files")
    request.setValue(
      "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

    onProgress?(.uploading(0))
    let (data, response) = try await URLSession.shared.upload(
      for: request, fromFile: tempURL,
      delegate: onProgress.map { handler in
        UploadProgressDelegate { handler(.uploading($0)) }
      })
    try checkHTTPResponse(response, data: data, context: "upload")

    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard let fileId = json?["id"] as? String else {
      throw TranscriptionError.uploadFailed("missing file id in response")
    }
    Log.info(Log.transcription, "transcription", "uploaded file: \(fileId)")
    return fileId
  }

  /// Streams the audio into a multipart body on disk in 64KB chunks. Stream
  /// errors and short writes are surfaced: swallowing them uploads a truncated
  /// body that the transport reports as a success and Soniox rejects much later,
  /// pointing nowhere near the real cause.
  private static func writeMultipartBody(audio fileURL: URL, boundary: String, to tempURL: URL)
    throws
  {
    FileManager.default.createFile(atPath: tempURL.path, contents: nil)
    guard let output = OutputStream(url: tempURL, append: false) else {
      throw TranscriptionError.uploadFailed("failed to create temp file for upload")
    }
    output.open()
    defer { output.close() }

    func writeAll(_ bytes: UnsafePointer<UInt8>, count: Int) throws {
      var offset = 0
      while offset < count {
        let written = output.write(bytes + offset, maxLength: count - offset)
        guard written > 0 else {
          throw TranscriptionError.uploadFailed(
            "short write building upload body: "
              + (output.streamError?.localizedDescription ?? "stream closed"))
        }
        offset += written
      }
    }

    let header = Data(
      "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\nContent-Type: audio/mp4\r\n\r\n"
        .utf8)
    try header.withUnsafeBytes { buffer in
      try writeAll(buffer.bindMemory(to: UInt8.self).baseAddress!, count: header.count)
    }

    guard let input = InputStream(url: fileURL) else {
      throw TranscriptionError.uploadFailed("failed to open audio file for reading")
    }
    input.open()
    defer { input.close() }

    let bufferSize = 65536
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }
    while input.hasBytesAvailable {
      let bytesRead = input.read(buffer, maxLength: bufferSize)
      if bytesRead > 0 {
        try writeAll(buffer, count: bytesRead)
      } else if bytesRead < 0 {
        throw TranscriptionError.uploadFailed(
          "failed reading audio for upload: "
            + (input.streamError?.localizedDescription ?? "unknown error"))
      } else {
        break
      }
    }

    let footer = Data("\r\n--\(boundary)--\r\n".utf8)
    try footer.withUnsafeBytes { buffer in
      try writeAll(buffer.bindMemory(to: UInt8.self).baseAddress!, count: footer.count)
    }
  }

  // MARK: - Create Transcription

  @concurrent
  func createTranscription(fileId: String, reference: String) async throws -> String {
    let config: [String: Any] = [
      "model": model,
      "file_id": fileId,
      "enable_language_identification": true,
      "enable_speaker_diarization": true,
      // Ties the remote job back to a recording directory, so an artifact this
      // client loses track of is still identifiable in the Soniox console.
      "client_reference_id": String(reference.prefix(Self.referenceLimit)),
    ]

    var request = try makeRequest(.post, "/v1/transcriptions")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: config)

    let (data, response) = try await URLSession.shared.data(for: request)
    try checkHTTPResponse(response, data: data, context: "create transcription")

    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard let transcriptionId = json?["id"] as? String else {
      throw TranscriptionError.transcriptionFailed("missing transcription id")
    }
    Log.info(
      Log.transcription, "transcription", "created transcription: \(transcriptionId)")
    return transcriptionId
  }

  // MARK: - Poll

  @concurrent
  func awaitCompletion(transcriptionId: String) async throws {
    var elapsed = Duration.zero

    while elapsed < Self.pollCeiling {
      try Task.checkCancellation()
      let interval = Self.pollInterval(after: elapsed)
      try await Task.sleep(for: interval)
      elapsed += interval

      let request = try makeRequest(.get, "/v1/transcriptions/\(transcriptionId)")
      let data: Data
      let response: URLResponse
      do {
        (data, response) = try await URLSession.shared.data(for: request)
        try checkHTTPResponse(response, data: data, context: "poll status")
      } catch let error as URLError
        where [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(
          error.code)
      {
        // A blip during a poll that can run for half an hour is not worth
        // spending one of the coordinator's persisted attempts on.
        Log.error(
          Log.transcription, "transcription",
          "poll network error, retrying: \(error.localizedDescription)")
        continue
      }

      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      switch json?["status"] as? String {
      case "completed":
        Log.info(Log.transcription, "transcription", "completed: \(transcriptionId)")
        return
      case "error":
        throw TranscriptionError.transcriptionFailed(
          json?["error_message"] as? String ?? "unknown error")
      default:
        break
      }
    }
    throw TranscriptionError.pollTimeout
  }

  /// Ramps the poll interval so a job that takes minutes does not cost hundreds
  /// of requests, while a short one is still noticed promptly.
  private static func pollInterval(after elapsed: Duration) -> Duration {
    switch elapsed {
    case ..<(.seconds(30)): .seconds(2)
    case ..<(.seconds(300)): .seconds(5)
    default: .seconds(15)
    }
  }

  // MARK: - Fetch Transcript

  @concurrent
  func fetchTranscript(
    transcriptionId: String
  ) async throws -> TranscriptDocument {
    let request = try makeRequest(
      .get, "/v1/transcriptions/\(transcriptionId)/transcript")
    let (data, response) = try await URLSession.shared.data(for: request)
    try checkHTTPResponse(response, data: data, context: "fetch transcript")

    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let tokens = json["tokens"] as? [[String: Any]], !tokens.isEmpty
    else {
      throw TranscriptionError.transcriptionFailed("empty or invalid transcript response")
    }

    var document = groupTokensIntoDocument(tokens)
    document.provider = Self.providerName
    document.model = model
    return document
  }

  private func groupTokensIntoDocument(_ tokens: [[String: Any]]) -> TranscriptDocument {
    var segments: [TranscriptSegment] = []
    var currentSpeaker: Int?
    var currentText = ""
    var currentTime: Double = 0

    for token in tokens {
      // Skip translation tokens
      if token["translation_status"] as? String == "translation" { continue }

      // Soniox v4+ returns speaker as String ("1", "2"), v3 returned Int
      let speaker: Int
      if let s = token["speaker"] as? Int {
        speaker = s
      } else if let s = token["speaker"] as? String, let i = Int(s) {
        speaker = i
      } else {
        speaker = 0
      }
      let text = token["text"] as? String ?? ""

      if speaker != currentSpeaker {
        if let s = currentSpeaker,
          !currentText.trimmingCharacters(in: .whitespaces)
            .isEmpty
        {
          segments.append(
            TranscriptSegment(
              speaker: s,
              time: currentTime,
              text: currentText.trimmingCharacters(in: .whitespaces)))
        }
        currentSpeaker = speaker
        currentText = ""
        currentTime = (token["start_ms"] as? Double ?? 0) / 1000.0
      }
      currentText += text
    }

    // Last segment
    if let s = currentSpeaker,
      !currentText.trimmingCharacters(in: .whitespaces).isEmpty
    {
      segments.append(
        TranscriptSegment(
          speaker: s,
          time: currentTime,
          text: currentText.trimmingCharacters(in: .whitespaces)))
    }

    let language =
      tokens.first(where: {
        $0["language"] as? String != nil
          && $0["translation_status"] as? String != "translation"
      })?["language"] as? String

    return TranscriptDocument(
      segments: segments, language: language, createdAt: Date())
  }

  // MARK: - Cleanup

  /// Best-effort removal of the remote file and transcription so the account
  /// does not accumulate artifacts. A failure here does not fail the job, but it
  /// is logged: this is the only thing standing between a finished job and the
  /// user's call audio living on Soniox indefinitely, so a silent miss is the
  /// one outcome that must not be invisible.
  @concurrent
  func deleteRemote(transcriptionIds: [String], fileIds: [String]) async {
    for tId in transcriptionIds {
      await delete(path: "/v1/transcriptions/\(tId)", describing: "transcription \(tId)")
    }
    for fId in fileIds {
      await delete(path: "/v1/files/\(fId)", describing: "file \(fId)")
    }
  }

  @concurrent
  private func delete(path: String, describing what: String) async {
    guard let url = URL(string: "\(baseURL)\(path)") else {
      Log.error(Log.transcription, "transcription", "cannot delete \(what): invalid URL \(path)")
      return
    }
    var request = URLRequest(url: url)
    request.httpMethod = "DELETE"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        Log.error(
          Log.transcription, "transcription",
          "cannot confirm deletion of \(what): no HTTP response; it may remain on Soniox")
        return
      }
      // 404 means it is already gone, which is the outcome we wanted.
      guard !(200..<300).contains(http.statusCode), http.statusCode != 404 else { return }
      Log.error(
        Log.transcription, "transcription",
        "failed to delete \(what) (HTTP \(http.statusCode)); it may remain on Soniox: \(Self.bodyExcerpt(from: data))"
      )
    } catch {
      Log.error(
        Log.transcription, "transcription",
        "failed to delete \(what); it may remain on Soniox: \(error.localizedDescription)")
    }
  }

  // MARK: - Helpers

  private enum HTTPMethod: String {
    case get = "GET"
    case post = "POST"
  }

  private func makeRequest(_ method: HTTPMethod, _ path: String) throws -> URLRequest {
    guard let url = URL(string: "\(baseURL)\(path)") else {
      throw TranscriptionError.transcriptionFailed("invalid URL: \(path)")
    }
    var request = URLRequest(url: url)
    request.httpMethod = method.rawValue
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    return request
  }

  /// Soniox errors carry `{status_code, error_type, message, request_id}`.
  /// `request_id` is what their support asks for, so it goes in the log even
  /// though the user never sees it.
  nonisolated private static func errorEnvelope(from data: Data) -> (
    message: String?, errorType: String?, requestId: String?
  ) {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return (nil, nil, nil)
    }
    return (
      json["message"] as? String, json["error_type"] as? String, json["request_id"] as? String
    )
  }

  /// A prefix of the raw body, for the failures that carry no Soniox envelope
  /// at all - a proxy's HTML error page, an empty 502, a truncated response.
  /// Without this the log says only "HTTP 502" and the cause is unrecoverable.
  nonisolated private static func bodyExcerpt(from data: Data) -> String {
    guard !data.isEmpty else { return "empty body" }
    let text = String(decoding: data.prefix(bodyLogLimit), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return "\(data.count) non-text bytes" }
    return data.count > bodyLogLimit ? text + "... (\(data.count) bytes)" : text
  }

  private func checkHTTPResponse(
    _ response: URLResponse, data: Data, context: String
  ) throws {
    guard let http = response as? HTTPURLResponse else { return }
    guard (200..<300).contains(http.statusCode) else {
      let envelope = Self.errorEnvelope(from: data)
      let apiMessage = envelope.message ?? "HTTP \(http.statusCode)"
      Log.error(
        Log.transcription, "transcription",
        "\(context) failed (\(http.statusCode) \(envelope.errorType ?? "unknown")): \(apiMessage) [request_id=\(envelope.requestId ?? "none")] body=\(Self.bodyExcerpt(from: data))"
      )
      let detail = "\(context): \(apiMessage)"

      switch http.statusCode {
      case 409:
        throw TranscriptionError.notReady(detail)
      case 402:
        throw TranscriptionError.balanceExhausted(apiMessage)
      case 429, 500...599:
        throw TranscriptionError.serverError(http.statusCode, detail)
      default:
        throw TranscriptionError.transcriptionFailed(detail)
      }
    }
  }
}
