import AVFoundation
import Foundation

// MARK: - Data Models

nonisolated struct TranscriptDocument: Codable, Sendable {
  var segments: [TranscriptSegment]
  var language: String?
  var createdAt: Date

  nonisolated static func sidecarURL(for recordingURL: URL) -> URL {
    recordingURL.deletingPathExtension().appendingPathExtension("transcript.json")
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

nonisolated enum TranscriptionStatus: Equatable, Sendable {
  case idle
  case uploading
  case queued
  case transcribing
  case completed
  case error(String)
}

nonisolated enum TranscriptionError: Error, LocalizedError, Sendable {
  case noAPIKey
  case uploadFailed(String)
  case transcriptionFailed(String)
  case pollTimeout
  case cancelled

  var errorDescription: String? {
    switch self {
    case .noAPIKey: "Soniox API key not configured"
    case .uploadFailed(let msg): "Upload failed: \(msg)"
    case .transcriptionFailed(let msg): "Transcription failed: \(msg)"
    case .pollTimeout: "Transcription timed out"
    case .cancelled: "Transcription cancelled"
    }
  }
}

// MARK: - Soniox API Client

final class TranscriptionService {
  private let apiKey: String
  private static let baseURL = "https://api.soniox.com"

  init(apiKey: String) {
    self.apiKey = apiKey
  }

  /// Transcribes an audio file. For dual-track recordings (system audio + mic),
  /// each track is transcribed separately for better speaker attribution:
  /// the mic track becomes "You" and system audio speakers are diarized independently.
  func transcribe(
    fileURL: URL,
    onStatus: @escaping (TranscriptionStatus) -> Void
  ) async throws -> TranscriptDocument {
    let asset = AVURLAsset(url: fileURL)
    let tracks = try await asset.loadTracks(withMediaType: .audio)

    if tracks.count >= 2 {
      Log.info(
        Log.transcription, "transcription",
        "dual-track file detected (\(tracks.count) tracks), transcribing separately")
      return try await transcribeDualTrack(fileURL: fileURL, onStatus: onStatus)
    } else {
      return try await transcribeSingleFile(fileURL: fileURL, onStatus: onStatus)
    }
  }

  // MARK: - Single File (mono or single-track)

  private func transcribeSingleFile(
    fileURL: URL,
    onStatus: @escaping (TranscriptionStatus) -> Void
  ) async throws -> TranscriptDocument {
    onStatus(.uploading)
    let fileId = try await uploadFile(fileURL)
    var transcriptionId: String?

    do {
      onStatus(.queued)
      transcriptionId = try await createTranscription(fileId: fileId, enableDiarization: true)
      try await pollUntilComplete(transcriptionId: transcriptionId!, onStatus: onStatus)
      let doc = try await fetchTranscript(transcriptionId: transcriptionId!)
      onStatus(.completed)
      fireAndForgetCleanup(transcriptionIds: [transcriptionId!], fileIds: [fileId])
      return doc
    } catch {
      fireAndForgetCleanup(
        transcriptionIds: [transcriptionId].compactMap { $0 }, fileIds: [fileId])
      throw error
    }
  }

  // MARK: - Dual Track (system audio + mic)

  private func transcribeDualTrack(
    fileURL: URL,
    onStatus: @escaping (TranscriptionStatus) -> Void
  ) async throws -> TranscriptDocument {
    onStatus(.uploading)

    // Extract each track to a temporary mono M4A
    let systemURL = try await extractTrack(from: fileURL, trackIndex: 0)
    let micURL = try await extractTrack(from: fileURL, trackIndex: 1)
    defer {
      try? FileManager.default.removeItem(at: systemURL)
      try? FileManager.default.removeItem(at: micURL)
    }

    // Upload both files in parallel
    async let systemUpload = uploadFile(systemURL)
    async let micUpload = uploadFile(micURL)
    let (sysFileId, micFileId) = try await (systemUpload, micUpload)

    // Create transcriptions: system audio with diarization, mic without
    async let systemCreate = createTranscription(fileId: sysFileId, enableDiarization: true)
    async let micCreate = createTranscription(fileId: micFileId, enableDiarization: false)
    let (sysTxId, micTxId) = try await (systemCreate, micCreate)

    onStatus(.transcribing)

    do {
      // Poll both in parallel
      async let sysPoll: Void = pollUntilComplete(
        transcriptionId: sysTxId, onStatus: { _ in })
      async let micPoll: Void = pollUntilComplete(
        transcriptionId: micTxId, onStatus: { _ in })
      try await sysPoll
      try await micPoll

      // Fetch both transcripts (either track may be silent)
      async let systemDoc = fetchTranscript(transcriptionId: sysTxId, allowEmpty: true)
      async let micDoc = fetchTranscript(transcriptionId: micTxId, allowEmpty: true)
      let (sysDoc, mDoc) = try await (systemDoc, micDoc)

      if sysDoc.segments.isEmpty && mDoc.segments.isEmpty {
        throw TranscriptionError.transcriptionFailed("no speech detected in either track")
      }

      let merged = mergeTranscripts(system: sysDoc, mic: mDoc)
      onStatus(.completed)
      fireAndForgetCleanup(
        transcriptionIds: [sysTxId, micTxId], fileIds: [sysFileId, micFileId])
      return merged
    } catch {
      fireAndForgetCleanup(
        transcriptionIds: [sysTxId, micTxId], fileIds: [sysFileId, micFileId])
      throw error
    }
  }

  // MARK: - Track Extraction

  private func extractTrack(from fileURL: URL, trackIndex: Int) async throws -> URL {
    let asset = AVURLAsset(url: fileURL)
    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
    guard trackIndex < audioTracks.count else {
      throw TranscriptionError.transcriptionFailed("audio track \(trackIndex) not found")
    }

    let composition = AVMutableComposition()
    guard
      let compositionTrack = composition.addMutableTrack(
        withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
    else {
      throw TranscriptionError.transcriptionFailed("could not create composition track")
    }

    let sourceTrack = audioTracks[trackIndex]
    let duration = try await asset.load(.duration)
    try compositionTrack.insertTimeRange(
      CMTimeRange(start: .zero, duration: duration),
      of: sourceTrack,
      at: .zero
    )

    let tempURL =
      FileManager.default.temporaryDirectory
      .appendingPathComponent("blackbox-track\(trackIndex)-\(UUID().uuidString).m4a")

    guard
      let exporter = AVAssetExportSession(
        asset: composition, presetName: AVAssetExportPresetAppleM4A)
    else {
      throw TranscriptionError.transcriptionFailed("could not create export session")
    }

    do {
      try await exporter.export(to: tempURL, as: .m4a)
    } catch {
      throw TranscriptionError.transcriptionFailed(
        "track export failed: \(error.localizedDescription)")
    }

    Log.info(Log.transcription, "transcription", "extracted track \(trackIndex) to temp file")
    return tempURL
  }

  // MARK: - Merge Transcripts

  /// Merges system audio and mic transcripts. Mic segments are labeled as speaker -1 ("You").
  private func mergeTranscripts(
    system: TranscriptDocument, mic: TranscriptDocument
  ) -> TranscriptDocument {
    let micSegments = mic.segments.map { segment in
      TranscriptSegment(speaker: -1, time: segment.time, text: segment.text)
    }

    var allSegments = system.segments + micSegments
    allSegments.sort { $0.time < $1.time }

    Log.info(
      Log.transcription, "transcription",
      "merged \(system.segments.count) system + \(mic.segments.count) mic segments")

    return TranscriptDocument(
      segments: allSegments,
      language: system.language ?? mic.language,
      createdAt: Date())
  }

  // MARK: - Upload

  private func uploadFile(_ fileURL: URL) async throws -> String {
    let boundary = UUID().uuidString
    var body = Data()
    let fileData = try Data(contentsOf: fileURL)
    let filename = fileURL.lastPathComponent

    body.append(Data("--\(boundary)\r\n".utf8))
    body.append(
      Data(
        "Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8))
    body.append(Data("Content-Type: audio/mp4\r\n\r\n".utf8))
    body.append(fileData)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))

    var request = try makeRequest(.post, "/v1/files")
    request.setValue(
      "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.httpBody = body

    let (data, response) = try await URLSession.shared.data(for: request)
    try checkHTTPResponse(response, data: data, context: "upload")

    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard let fileId = json?["id"] as? String else {
      throw TranscriptionError.uploadFailed("missing file id in response")
    }
    Log.info(Log.transcription, "transcription", "uploaded file: \(fileId)")
    return fileId
  }

  // MARK: - Create Transcription

  private func createTranscription(
    fileId: String, enableDiarization: Bool
  ) async throws -> String {
    var config: [String: Any] = [
      "model": "stt-async-v3",
      "file_id": fileId,
      "language_hints": ["en"],
      "enable_language_identification": true,
    ]
    if enableDiarization {
      config["enable_speaker_diarization"] = true
    }

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

  private func pollUntilComplete(
    transcriptionId: String,
    onStatus: @escaping (TranscriptionStatus) -> Void
  ) async throws {
    var didReportTranscribing = false

    for _ in 0..<900 {  // 900 * 2s = 30 minutes max
      try Task.checkCancellation()
      try await Task.sleep(for: .seconds(2))

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
        Log.error(
          Log.transcription, "transcription",
          "poll network error, retrying: \(error.localizedDescription)")
        continue
      }

      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      let status = json?["status"] as? String

      switch status {
      case "completed":
        Log.info(Log.transcription, "transcription", "completed: \(transcriptionId)")
        return
      case "error":
        let msg = json?["error_message"] as? String ?? "unknown error"
        throw TranscriptionError.transcriptionFailed(msg)
      case "transcribing" where !didReportTranscribing:
        didReportTranscribing = true
        onStatus(.transcribing)
      default:
        break
      }
    }
    throw TranscriptionError.pollTimeout
  }

  // MARK: - Fetch Transcript

  private func fetchTranscript(
    transcriptionId: String, allowEmpty: Bool = false
  ) async throws -> TranscriptDocument {
    let request = try makeRequest(
      .get, "/v1/transcriptions/\(transcriptionId)/transcript")
    let (data, response) = try await URLSession.shared.data(for: request)
    try checkHTTPResponse(response, data: data, context: "fetch transcript")

    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let tokens = json["tokens"] as? [[String: Any]], !tokens.isEmpty
    else {
      if allowEmpty {
        return TranscriptDocument(segments: [], language: nil, createdAt: Date())
      }
      throw TranscriptionError.transcriptionFailed("empty or invalid transcript response")
    }

    return groupTokensIntoDocument(tokens)
  }

  private func groupTokensIntoDocument(_ tokens: [[String: Any]]) -> TranscriptDocument {
    var segments: [TranscriptSegment] = []
    var currentSpeaker: Int?
    var currentText = ""
    var currentTime: Double = 0

    for token in tokens {
      // Skip translation tokens
      if token["translation_status"] as? String == "translation" { continue }

      let speaker = token["speaker"] as? Int ?? 0
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

  private func fireAndForgetCleanup(transcriptionIds: [String], fileIds: [String]) {
    let key = apiKey
    Task.detached {
      await TranscriptionService.cleanup(
        transcriptionIds: transcriptionIds, fileIds: fileIds, apiKey: key)
    }
  }

  nonisolated private static func cleanup(
    transcriptionIds: [String], fileIds: [String], apiKey: String
  ) async {
    let base = "https://api.soniox.com"
    for tId in transcriptionIds {
      guard let url = URL(string: "\(base)/v1/transcriptions/\(tId)") else { continue }
      var req = URLRequest(url: url)
      req.httpMethod = "DELETE"
      req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
      _ = try? await URLSession.shared.data(for: req)
    }
    for fId in fileIds {
      guard let url = URL(string: "\(base)/v1/files/\(fId)") else { continue }
      var req = URLRequest(url: url)
      req.httpMethod = "DELETE"
      req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
      _ = try? await URLSession.shared.data(for: req)
    }
  }

  // MARK: - Helpers

  private enum HTTPMethod: String {
    case get = "GET"
    case post = "POST"
    case delete = "DELETE"
  }

  private func makeRequest(_ method: HTTPMethod, _ path: String) throws -> URLRequest {
    guard let url = URL(string: "\(Self.baseURL)\(path)") else {
      throw TranscriptionError.transcriptionFailed("invalid URL: \(path)")
    }
    var request = URLRequest(url: url)
    request.httpMethod = method.rawValue
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    return request
  }

  private func checkHTTPResponse(
    _ response: URLResponse, data: Data, context: String
  ) throws {
    guard let http = response as? HTTPURLResponse else { return }
    guard (200..<300).contains(http.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? "no body"
      Log.error(
        Log.transcription, "transcription",
        "\(context) failed (\(http.statusCode)): \(body)")
      let apiMsg: String
      if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let msg = json["error"] as? String ?? json["message"] as? String
      {
        apiMsg = msg
      } else {
        apiMsg = "HTTP \(http.statusCode)"
      }
      throw TranscriptionError.transcriptionFailed(
        "\(context): \(apiMsg)")
    }
  }
}
