import AVFoundation
import Foundation

// MARK: - Data Models

nonisolated struct RecordingMetadata: Codable, Sendable {
  var title: String
  var createdAt: Date
  var appName: String
  var speakers: [String: String]

  static let fileName = "metadata.json"

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

nonisolated struct ExportedSegment: Codable, Sendable {
  var speaker: String
  var time: String
  var text: String
}

nonisolated struct TranscriptDocument: Codable, Sendable {
  var segments: [TranscriptSegment]
  var language: String?
  var createdAt: Date

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

nonisolated enum TranscriptionStatus: Equatable, Sendable {
  case idle
  case uploading
  case queued
  case transcribing
  case completed
  case error(String)
}

nonisolated enum TranscriptionError: Error, LocalizedError, Sendable {
  case uploadFailed(String)
  case transcriptionFailed(String)
  case pollTimeout

  var errorDescription: String? {
    switch self {
    case .uploadFailed(let msg): "Upload failed: \(msg)"
    case .transcriptionFailed(let msg): "Transcription failed: \(msg)"
    case .pollTimeout: "Transcription timed out"
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
  /// tracks are mixed into a single file first so Soniox can diarize speakers
  /// from the combined audio, producing proper speaker separation and timestamps.
  func transcribe(
    fileURL: URL,
    onStatus: @escaping (TranscriptionStatus) -> Void
  ) async throws -> TranscriptDocument {
    let asset = AVURLAsset(url: fileURL)
    let tracks = try await asset.loadTracks(withMediaType: .audio)

    var uploadURL = fileURL
    var needsCleanup = false

    if tracks.count >= 2 {
      Log.info(
        Log.transcription, "transcription",
        "dual-track file detected (\(tracks.count) tracks), mixing before transcription")
      uploadURL = try await Self.mixTracks(from: fileURL)
      needsCleanup = true
    }

    defer {
      if needsCleanup {
        try? FileManager.default.removeItem(at: uploadURL)
      }
    }

    onStatus(.uploading)
    let fileId = try await uploadFile(uploadURL)
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

  // MARK: - Audio Mixing & Export

  /// Mixes all audio tracks into a single-track M4A for unified transcription/export.
  static func mixTracks(from fileURL: URL) async throws -> URL {
    let asset = AVURLAsset(url: fileURL)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    guard tracks.count >= 2 else { return fileURL }

    let composition = AVMutableComposition()
    let duration = try await asset.load(.duration)

    for sourceTrack in tracks {
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
      .appendingPathComponent("blackbox-mixed-\(UUID().uuidString).m4a")

    guard
      let exporter = AVAssetExportSession(
        asset: composition, presetName: AVAssetExportPresetAppleM4A)
    else {
      throw TranscriptionError.transcriptionFailed("could not create export session for mixing")
    }

    do {
      try await exporter.export(to: tempURL, as: .m4a)
    } catch {
      throw TranscriptionError.transcriptionFailed(
        "track mixing failed: \(error.localizedDescription)")
    }

    Log.info(Log.transcription, "transcription", "mixed \(tracks.count) tracks into single file")
    return tempURL
  }

  /// Exports a single-track M4A copy. Mixes tracks first if multi-track.
  static func exportM4A(from fileURL: URL, to outputURL: URL) async throws {
    let asset = AVURLAsset(url: fileURL)
    let tracks = try await asset.loadTracks(withMediaType: .audio)

    if tracks.count >= 2 {
      let mixed = try await mixTracks(from: fileURL)
      defer { try? FileManager.default.removeItem(at: mixed) }
      try FileManager.default.copyItem(at: mixed, to: outputURL)
    } else {
      try FileManager.default.copyItem(at: fileURL, to: outputURL)
    }
  }

  // MARK: - Upload

  private func uploadFile(_ fileURL: URL) async throws -> String {
    let boundary = UUID().uuidString
    let filename = fileURL.lastPathComponent

    // Build multipart body as a temp file to avoid loading entire audio into memory
    let tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString + ".multipart")
    FileManager.default.createFile(atPath: tempURL.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: tempURL) }

    guard let output = OutputStream(url: tempURL, append: false) else {
      throw TranscriptionError.uploadFailed("failed to create temp file for upload")
    }
    output.open()

    let header = Data(
      "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: audio/mp4\r\n\r\n"
        .utf8)
    header.withUnsafeBytes { buf in
      _ = output.write(buf.bindMemory(to: UInt8.self).baseAddress!, maxLength: header.count)
    }

    // Stream file content in 64KB chunks
    guard let input = InputStream(url: fileURL) else {
      output.close()
      throw TranscriptionError.uploadFailed("failed to open audio file for reading")
    }
    input.open()
    let bufferSize = 65536
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }
    while input.hasBytesAvailable {
      let bytesRead = input.read(buffer, maxLength: bufferSize)
      if bytesRead > 0 {
        _ = output.write(buffer, maxLength: bytesRead)
      } else {
        break
      }
    }
    input.close()

    let footer = Data("\r\n--\(boundary)--\r\n".utf8)
    footer.withUnsafeBytes { buf in
      _ = output.write(buf.bindMemory(to: UInt8.self).baseAddress!, maxLength: footer.count)
    }
    output.close()

    var request = try makeRequest(.post, "/v1/files")
    request.setValue(
      "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

    let (data, response) = try await URLSession.shared.upload(for: request, fromFile: tempURL)
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
      "model": "stt-async-v4",
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

      // Soniox v4 returns speaker as String ("1", "2"), v3 returned Int
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
