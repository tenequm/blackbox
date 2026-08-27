import Foundation
import Testing
import os

@testable import Blackbox

// MARK: - Loopback HTTP Stub

/// Minimal HTTP/1.1 server on 127.0.0.1, used to drive the real
/// `TranscriptionService` against Soniox's documented wire format.
///
/// A real socket rather than a `URLProtocol` mock on purpose: the multipart body
/// is streamed from a file through `URLSession.upload(fromFile:)`, and a mock
/// stubs out precisely the layer where that can go wrong. Plain BSD sockets
/// rather than `NWListener`, which fails to bind with EINVAL on macOS 26.
nonisolated final class StubHTTPServer: @unchecked Sendable {
  struct Request: Sendable {
    let method: String
    let path: String
    let body: Data
  }

  struct Response: Sendable {
    var status: Int = 200
    var body: Data = Data()

    static func json(_ status: Int = 200, _ object: [String: Any]) -> Response {
      Response(
        status: status,
        body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }
  }

  enum StubError: Error { case didNotStart(String) }

  private let listenFD: Int32
  private let handler: @Sendable (Request) -> Response
  private let lock = NSLock()
  private var recorded: [Request] = []
  private var isStopped = false

  let baseURL: String

  init(handler: @escaping @Sendable (Request) -> Response) throws {
    self.handler = handler

    let fileDescriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard fileDescriptor >= 0 else { throw StubError.didNotStart("socket: \(errno)") }
    var reuse: Int32 = 1
    setsockopt(
      fileDescriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr.s_addr = inet_addr("127.0.0.1")

    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fileDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0, listen(fileDescriptor, 16) == 0 else {
      close(fileDescriptor)
      throw StubError.didNotStart("bind/listen: \(errno)")
    }

    var assigned = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &assigned) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(fileDescriptor, $0, &length)
      }
    }

    listenFD = fileDescriptor
    baseURL = "http://127.0.0.1:\(UInt16(bigEndian: assigned.sin_port))"
    Thread.detachNewThread { [self] in serve() }
  }

  deinit {
    stop()
  }

  func stop() {
    lock.lock()
    let alreadyStopped = isStopped
    isStopped = true
    lock.unlock()
    if !alreadyStopped { close(listenFD) }
  }

  var requests: [Request] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  func requests(path: String) -> [Request] {
    requests.filter { $0.path == path }
  }

  // MARK: Serving

  private func serve() {
    while true {
      let client = accept(listenFD, nil, nil)
      if client < 0 {
        lock.lock()
        let stopped = isStopped
        lock.unlock()
        if stopped { return }
        continue
      }
      var noSignal: Int32 = 1
      setsockopt(
        client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
      handle(client)
      close(client)
    }
  }

  private func handle(_ client: Int32) {
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 65536)

    var headerEnd: Range<Data.Index>?
    while headerEnd == nil {
      let count = read(client, &chunk, chunk.count)
      if count <= 0 { return }
      buffer.append(contentsOf: chunk[0..<count])
      headerEnd = buffer.range(of: Data("\r\n\r\n".utf8))
    }
    guard let headerEnd,
      let head = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8)
    else { return }

    let lines = head.components(separatedBy: "\r\n")
    let startLine = lines.first?.components(separatedBy: " ") ?? []
    guard startLine.count >= 2 else { return }

    var contentLength = 0
    var expectsContinue = false
    for line in lines.dropFirst() {
      let parts = line.split(separator: ":", maxSplits: 1).map {
        $0.trimmingCharacters(in: .whitespaces)
      }
      guard parts.count == 2 else { continue }
      switch parts[0].lowercased() {
      case "content-length": contentLength = Int(parts[1]) ?? 0
      case "expect": expectsContinue = parts[1].lowercased().contains("100-continue")
      default: break
      }
    }

    // URLSession asks to withhold a large upload body until the server agrees.
    if expectsContinue {
      write(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), to: client)
    }

    var body = Data(buffer[headerEnd.upperBound...])
    while body.count < contentLength {
      let count = read(client, &chunk, chunk.count)
      if count <= 0 { break }
      body.append(contentsOf: chunk[0..<count])
    }

    let request = Request(method: startLine[0], path: startLine[1], body: body)
    lock.lock()
    recorded.append(request)
    lock.unlock()

    let response = handler(request)
    var head2 = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
    head2 += "Content-Type: application/json\r\n"
    head2 += "Content-Length: \(response.body.count)\r\n"
    head2 += "Connection: close\r\n\r\n"
    var payload = Data(head2.utf8)
    payload.append(response.body)
    write(payload, to: client)
  }

  private func write(_ data: Data, to client: Int32) {
    data.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return }
      var sent = 0
      while sent < raw.count {
        let count = Darwin.write(client, base.advanced(by: sent), raw.count - sent)
        if count <= 0 { return }
        sent += count
      }
    }
  }

  private static func reason(_ status: Int) -> String {
    switch status {
    case 200: "OK"
    case 201: "Created"
    case 401: "Unauthorized"
    case 402: "Payment Required"
    case 409: "Conflict"
    case 429: "Too Many Requests"
    case 500: "Internal Server Error"
    default: "Status"
    }
  }
}

// MARK: - Contract Fixtures

/// The error envelope Soniox documents for every non-2xx response.
nonisolated private func errorEnvelope(_ status: Int, _ type: String, _ message: String)
  -> [String: Any]
{
  [
    "status_code": status,
    "error_type": type,
    "message": message,
    "validation_errors": [],
    "request_id": "req-abc123",
  ]
}

/// A transcript response in the documented shape: `speaker` is a string, times
/// are integer milliseconds.
nonisolated private func transcriptPayload() -> [String: Any] {
  [
    "id": "19b6d61d-02db-4c25-bc71-b4094dc310c8",
    "text": "Hello there General",
    "tokens": [
      [
        "text": "Hello", "start_ms": 0, "end_ms": 400, "confidence": 0.98, "speaker": "1",
        "language": "en",
      ],
      [
        "text": " there", "start_ms": 400, "end_ms": 800, "confidence": 0.97, "speaker": "1",
        "language": "en",
      ],
      [
        "text": "General", "start_ms": 1500, "end_ms": 2200, "confidence": 0.95, "speaker": "2",
        "language": "en",
      ],
    ],
  ]
}

nonisolated private func makeAudioFile(sampleCount: Int = 48_000) throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("blackbox-contract-\(UUID().uuidString).wav")

  let sampleRate = 8000
  let dataBytes = sampleCount * 2
  var file = Data()
  func append(_ string: String) { file.append(contentsOf: Array(string.utf8)) }
  func append32(_ value: Int) {
    file.append(contentsOf: withUnsafeBytes(of: UInt32(value).littleEndian, Array.init))
  }
  func append16(_ value: Int) {
    file.append(contentsOf: withUnsafeBytes(of: UInt16(value).littleEndian, Array.init))
  }

  append("RIFF")
  append32(36 + dataBytes)
  append("WAVE")
  append("fmt ")
  append32(16)
  append16(1)  // PCM
  append16(1)  // mono
  append32(sampleRate)
  append32(sampleRate * 2)  // byte rate
  append16(2)  // block align
  append16(16)  // bits per sample
  append("data")
  append32(dataBytes)
  // A recognisable pattern so the multipart body can be checked byte for byte.
  for index in 0..<sampleCount {
    file.append(contentsOf: withUnsafeBytes(of: Int16(index % 3000).littleEndian, Array.init))
  }

  try file.write(to: url)
  return url
}

// MARK: - Tests

@Suite("Soniox Contract")
struct SonioxContractTests {

  @Test("create sends the documented request body")
  func createSendsDocumentedBody() async throws {
    let server = try StubHTTPServer { _ in
      .json(201, ["id": "transcription-1", "status": "queued"])
    }
    let service = TranscriptionService(
      apiKey: "k", model: "stt-async-v5", baseURL: server.baseURL)

    let id = try await service.createTranscription(fileId: "file-1", reference: "2026-03-11-call")
    #expect(id == "transcription-1")

    let request = try #require(server.requests(path: "/v1/transcriptions").first)
    let body = try #require(
      try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
    #expect(request.method == "POST")
    #expect(body["model"] as? String == "stt-async-v5")
    #expect(body["file_id"] as? String == "file-1")
    #expect(body["enable_speaker_diarization"] as? Bool == true)
    #expect(body["enable_language_identification"] as? Bool == true)
    #expect(body["client_reference_id"] as? String == "2026-03-11-call")
  }

  @Test("a blank configured model falls back to the default")
  func blankModelFallsBack() {
    #expect(TranscriptionService.resolvedModel(nil) == TranscriptionService.defaultModel)
    #expect(TranscriptionService.resolvedModel("") == TranscriptionService.defaultModel)
    #expect(TranscriptionService.resolvedModel("   ") == TranscriptionService.defaultModel)
    #expect(TranscriptionService.resolvedModel("stt-async-v9") == "stt-async-v9")
  }

  @Test("the configured model is what gets sent")
  func honoursConfiguredModel() async throws {
    let server = try StubHTTPServer { _ in .json(201, ["id": "t-1"]) }
    let service = TranscriptionService(
      apiKey: "k", model: "stt-async-v9-future", baseURL: server.baseURL)

    _ = try await service.createTranscription(fileId: "f", reference: "r")

    let request = try #require(server.requests(path: "/v1/transcriptions").first)
    let body = try JSONSerialization.jsonObject(with: request.body) as? [String: Any]
    #expect(body?["model"] as? String == "stt-async-v9-future")
  }

  @Test("the upload body carries the audio bytes intact")
  func uploadTransmitsAudioIntact() async throws {
    let server = try StubHTTPServer { _ in .json(200, ["id": "file-1"]) }
    let audioURL = try makeAudioFile()
    defer { try? FileManager.default.removeItem(at: audioURL) }
    let audio = try Data(contentsOf: audioURL)

    let service = TranscriptionService(apiKey: "k", baseURL: server.baseURL)
    let fileId = try await service.upload(fileURL: audioURL)
    #expect(fileId == "file-1")

    let request = try #require(server.requests(path: "/v1/files").first)
    #expect(request.method == "POST")
    // The multipart wrapper adds a header and footer; the payload between them
    // has to be the file, byte for byte.
    #expect(request.body.count > audio.count)
    #expect(request.body.range(of: audio) != nil)
  }

  @Test("a completed transcript decodes into speaker-grouped segments")
  func decodesTranscriptIntoSegments() async throws {
    let server = try StubHTTPServer { _ in .json(200, transcriptPayload()) }
    let service = TranscriptionService(
      apiKey: "k", model: "stt-async-v5", baseURL: server.baseURL)

    let document = try await service.fetchTranscript(transcriptionId: "t-1")

    #expect(document.segments.count == 2)
    #expect(document.segments.first?.speaker == 1)
    #expect(document.segments.first?.text == "Hello there")
    #expect(document.segments.last?.speaker == 2)
    // start_ms 1500 -> 1.5s
    #expect(document.segments.last?.time == 1.5)
    #expect(document.language == "en")
    // Provenance is stamped at the source so a transcript can be attributed later.
    #expect(document.provider == "soniox")
    #expect(document.model == "stt-async-v5")
  }

  @Test("409 on the transcript endpoint is a not-ready signal, not a failure")
  func notReadyIsDistinctFromFailure() async throws {
    let server = try StubHTTPServer { _ in
      .json(
        409,
        errorEnvelope(
          409, "transcription_invalid_state", "Transcription is still processing."))
    }
    let service = TranscriptionService(apiKey: "k", baseURL: server.baseURL)

    await #expect(throws: TranscriptionError.self) {
      _ = try await service.fetchTranscript(transcriptionId: "t-1")
    }
    do {
      _ = try await service.fetchTranscript(transcriptionId: "t-1")
    } catch let error as TranscriptionError {
      guard case .notReady = error else {
        Issue.record("expected .notReady, got \(error)")
        return
      }
    }
  }

  @Test("402 reports an exhausted balance rather than a generic failure")
  func balanceExhaustedIsRecognised() async throws {
    let server = try StubHTTPServer { _ in
      .json(
        402,
        errorEnvelope(
          402, "organization_balance_exhausted", "Prepaid balance has dropped to zero."))
    }
    let service = TranscriptionService(apiKey: "k", baseURL: server.baseURL)

    do {
      _ = try await service.createTranscription(fileId: "f", reference: "r")
      Issue.record("expected a throw")
    } catch let error as TranscriptionError {
      guard case .balanceExhausted(let message) = error else {
        Issue.record("expected .balanceExhausted, got \(error)")
        return
      }
      #expect(message.contains("Prepaid balance"))
    }
  }

  @Test("429 and 5xx map to retryable server errors", arguments: [429, 500, 503])
  func serverErrorsAreRetryable(status: Int) async throws {
    let server = try StubHTTPServer { _ in
      .json(status, errorEnvelope(status, "limit_exceeded", "Slow down."))
    }
    let service = TranscriptionService(apiKey: "k", baseURL: server.baseURL)

    do {
      _ = try await service.createTranscription(fileId: "f", reference: "r")
      Issue.record("expected a throw")
    } catch let error as TranscriptionError {
      guard case .serverError(let code, _) = error else {
        Issue.record("expected .serverError, got \(error)")
        return
      }
      #expect(code == status)
    }
  }

  @Test("a transcription that ends in error surfaces the server's reason")
  func transcriptionErrorStatusSurfacesMessage() async throws {
    let server = try StubHTTPServer { _ in
      .json(200, ["id": "t-1", "status": "error", "error_message": "unsupported audio format"])
    }
    let service = TranscriptionService(apiKey: "k", baseURL: server.baseURL)

    do {
      try await service.awaitCompletion(transcriptionId: "t-1")
      Issue.record("expected a throw")
    } catch let error as TranscriptionError {
      guard case .transcriptionFailed(let message) = error else {
        Issue.record("expected .transcriptionFailed, got \(error)")
        return
      }
      #expect(message.contains("unsupported audio format"))
    }
  }

  @Test("polling walks the documented status values through to completion")
  func pollsUntilCompleted() async throws {
    let polls = OSAllocatedUnfairLock(initialState: 0)
    let server = try StubHTTPServer { _ in
      let count = polls.withLock { value -> Int in
        value += 1
        return value
      }
      // queued -> processing -> completed, exactly the documented enum.
      let status = count == 1 ? "queued" : (count == 2 ? "processing" : "completed")
      return .json(200, ["id": "t-1", "status": status])
    }
    let service = TranscriptionService(apiKey: "k", baseURL: server.baseURL)

    try await service.awaitCompletion(transcriptionId: "t-1")

    #expect(polls.withLock { $0 } == 3)
  }

  @Test("key verification accepts a working key and reports a rejected one")
  func verifiesAPIKey() async throws {
    let good = try StubHTTPServer { _ in .json(200, ["files": []]) }
    let goodResult = await TranscriptionService.verifyAPIKey("k", baseURL: good.baseURL)
    #expect(goodResult.isValid)
    #expect(goodResult.message == nil)

    let bad = try StubHTTPServer { _ in
      .json(401, errorEnvelope(401, "unauthenticated", "Invalid API key."))
    }
    let badResult = await TranscriptionService.verifyAPIKey("k", baseURL: bad.baseURL)
    #expect(!badResult.isValid)
    #expect(badResult.message == "Invalid API key.")

    let empty = await TranscriptionService.verifyAPIKey("  ", baseURL: good.baseURL)
    #expect(!empty.isValid)
  }

  @Test("cleanup deletes both the transcription and the uploaded file")
  func deleteRemoteHitsBothEndpoints() async throws {
    let server = try StubHTTPServer { _ in .json(200, [:]) }
    let service = TranscriptionService(apiKey: "k", baseURL: server.baseURL)

    await service.deleteRemote(transcriptionIds: ["t-1"], fileIds: ["f-1"])

    let paths = server.requests.map(\.path)
    #expect(paths.contains("/v1/transcriptions/t-1"))
    #expect(paths.contains("/v1/files/f-1"))
    #expect(server.requests.allSatisfy { $0.method == "DELETE" })
  }
}
