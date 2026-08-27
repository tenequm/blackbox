import Foundation
import Testing

@testable import Blackbox

// MARK: - Test Doubles

/// Scriptable stand-in for the Soniox client. An actor so the counters a test
/// asserts on cannot race the coordinator's job runner.
actor FakeTranscriptionService: TranscriptionServicing {
  private(set) var uploadCount = 0
  private(set) var createCount = 0
  private(set) var completionCount = 0
  private(set) var fetchCount = 0
  private(set) var deletedTranscriptionIds: [String] = []
  private(set) var deletedFileIds: [String] = []
  private(set) var references: [String] = []

  private var uploadError: Error?
  /// Consumed one per `awaitCompletion` call, so a test can fail then succeed.
  private var completionErrors: [Error] = []
  private var holdsCompletion = false
  private let document = TranscriptDocument(
    segments: [TranscriptSegment(speaker: 1, time: 0, text: "hello")],
    language: "en",
    createdAt: Date(timeIntervalSince1970: 1_700_000_000)
  )

  func setUploadError(_ error: Error?) { uploadError = error }
  func setCompletionErrors(_ errors: [Error]) { completionErrors = errors }
  func setHoldsCompletion(_ holds: Bool) { holdsCompletion = holds }

  func upload(fileURL: URL) async throws -> String {
    uploadCount += 1
    if let uploadError { throw uploadError }
    return "file-\(uploadCount)"
  }

  func createTranscription(fileId: String, reference: String) async throws -> String {
    createCount += 1
    references.append(reference)
    return "transcription-\(createCount)"
  }

  func awaitCompletion(transcriptionId: String) async throws {
    completionCount += 1
    if !completionErrors.isEmpty { throw completionErrors.removeFirst() }
    if holdsCompletion {
      // Released only by cancellation, which surfaces as a thrown CancellationError.
      try await Task.sleep(for: .seconds(60))
    }
  }

  func fetchTranscript(transcriptionId: String) async throws -> TranscriptDocument {
    fetchCount += 1
    return document
  }

  func deleteRemote(transcriptionIds: [String], fileIds: [String]) async {
    deletedTranscriptionIds.append(contentsOf: transcriptionIds)
    deletedFileIds.append(contentsOf: fileIds)
  }
}

@MainActor
final class TranscriptionHarness {
  let root: URL
  let service = FakeTranscriptionService()

  var apiKey: String? = "test-key"
  var autoEnabled = true
  var recordingActive = false
  /// Backoff and gate waits are no-ops by default so retries resolve instantly.
  var sleepHandler: @Sendable (Duration) async -> Void = { _ in }

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("blackbox-transcription-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: root)
  }

  /// Creates a recording directory holding a placeholder `audio.m4a`. The fake
  /// never reads it; only its existence matters to the coordinator.
  @discardableResult
  func makeRecording(_ name: String) throws -> URL {
    let directory = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data([0]).write(to: directory.appendingPathComponent("audio.m4a"))
    return directory
  }

  func makeCoordinator() -> TranscriptionCoordinator {
    let coordinator = TranscriptionCoordinator(
      dependencies: TranscriptionCoordinator.Dependencies(
        makeService: { [service] _ in service },
        apiKey: { [weak self] in self?.apiKey ?? nil },
        isAutoEnabled: { [weak self] in self?.autoEnabled ?? false },
        saveDirectory: { [root] in root },
        sleep: { [sleepHandler] duration in await sleepHandler(duration) }
      ))
    coordinator.isRecordingActive = { [weak self] in self?.recordingActive ?? false }
    return coordinator
  }

  /// Polls until `condition` holds. The coordinator hops between the main actor
  /// and the service actor, so yielding a fixed number of times is not enough.
  func wait(
    upTo timeout: TimeInterval = 5,
    for condition: @MainActor () async -> Bool
  ) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if await condition() { return }
      await Task.yield()
      try? await Task.sleep(for: .milliseconds(2))
    }
  }
}

// MARK: - Tests

@MainActor
@Suite("Transcription Coordinator")
struct TranscriptionCoordinatorTests {

  // MARK: Trigger decision

  @Test("auto-transcribes a finished recording when the setting and key are present")
  func autoTranscribesWhenEnabled() async throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.recordingFinished(audioFileURL: directory.appendingPathComponent("audio.m4a"))
    await harness.wait { coordinator.status(for: directory) == .completed }

    #expect(coordinator.status(for: directory) == .completed)
    #expect(TranscriptDocument.load(for: directory)?.segments.count == 1)
    #expect(await harness.service.uploadCount == 1)
    // The job sidecar exists only while work is outstanding.
    #expect(TranscriptionJob.load(for: directory) == nil)
    #expect(await harness.service.deletedFileIds == ["file-1"])
    // The remote job is tagged with the recording it belongs to.
    #expect(await harness.service.references == ["call-1"])
  }

  @Test("a 409 while fetching the transcript is retried, not treated as failure")
  func retriesNotReady() async throws {
    let harness = try TranscriptionHarness()
    await harness.service.setCompletionErrors([
      TranscriptionError.notReady("fetch transcript: still processing")
    ])
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.transcribe(recordingDirectory: directory)
    await harness.wait { coordinator.status(for: directory) == .completed }

    #expect(await harness.service.uploadCount == 1)
    #expect(TranscriptDocument.load(for: directory) != nil)
  }

  @Test("an exhausted balance fails terminally instead of retrying")
  func balanceExhaustedIsTerminal() async throws {
    let harness = try TranscriptionHarness()
    await harness.service.setUploadError(
      TranscriptionError.balanceExhausted("prepaid balance is zero"))
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.transcribe(recordingDirectory: directory)
    await harness.wait {
      if case .error = coordinator.status(for: directory) { return true }
      return false
    }

    // Retrying a dead balance just spends time; one attempt only.
    #expect(await harness.service.uploadCount == 1)
  }

  @Test("does not auto-transcribe when the setting is off")
  func skipsWhenSettingOff() async throws {
    let harness = try TranscriptionHarness()
    harness.autoEnabled = false
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.recordingFinished(audioFileURL: directory.appendingPathComponent("audio.m4a"))
    await harness.wait(upTo: 0.2) { await harness.service.uploadCount > 0 }

    #expect(await harness.service.uploadCount == 0)
    #expect(coordinator.status(for: directory) == .idle)
    #expect(TranscriptionJob.load(for: directory) == nil)
  }

  @Test("does not auto-transcribe when no API key is configured")
  func skipsWhenNoAPIKey() async throws {
    let harness = try TranscriptionHarness()
    harness.apiKey = nil
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.recordingFinished(audioFileURL: directory.appendingPathComponent("audio.m4a"))
    await harness.wait(upTo: 0.2) { await harness.service.uploadCount > 0 }

    #expect(await harness.service.uploadCount == 0)
    #expect(!coordinator.hasAPIKey)
    #expect(TranscriptionJob.load(for: directory) == nil)
  }

  @Test("manual transcription ignores the auto-transcribe setting")
  func manualIgnoresAutoSetting() async throws {
    let harness = try TranscriptionHarness()
    harness.autoEnabled = false
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.transcribe(recordingDirectory: directory)
    await harness.wait { coordinator.status(for: directory) == .completed }

    #expect(await harness.service.uploadCount == 1)
  }

  // MARK: Queueing

  @Test("enqueueing the same recording twice runs it once")
  func duplicateEnqueueRunsOnce() async throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.transcribe(recordingDirectory: directory)
    coordinator.transcribe(recordingDirectory: directory)
    await harness.wait { coordinator.status(for: directory) == .completed }
    await harness.wait(upTo: 0.2) { await harness.service.uploadCount > 1 }

    #expect(await harness.service.uploadCount == 1)
  }

  @Test("a second recording waits while the first is in flight")
  func jobsRunOneAtATime() async throws {
    let harness = try TranscriptionHarness()
    await harness.service.setHoldsCompletion(true)
    let first = try harness.makeRecording("call-1")
    let second = try harness.makeRecording("call-2")
    let coordinator = harness.makeCoordinator()

    coordinator.transcribe(recordingDirectory: first)
    coordinator.transcribe(recordingDirectory: second)
    await harness.wait { await harness.service.completionCount == 1 }

    #expect(await harness.service.uploadCount == 1)
    #expect(coordinator.status(for: second) == .queued)

    coordinator.cancel(recordingDirectory: first)
    await harness.wait { await harness.service.uploadCount == 2 }
    #expect(await harness.service.uploadCount == 2)
  }

  @Test("transcription is held back while a recording is in progress")
  func defersWhileRecording() async throws {
    let harness = try TranscriptionHarness()
    harness.recordingActive = true
    // A real wait keeps the gate from spinning hot while the flag stays set.
    harness.sleepHandler = { _ in try? await Task.sleep(for: .milliseconds(5)) }
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.transcribe(recordingDirectory: directory)
    await harness.wait(upTo: 0.2) { await harness.service.uploadCount > 0 }
    #expect(await harness.service.uploadCount == 0)
    #expect(coordinator.status(for: directory) == .queued)

    harness.recordingActive = false
    await harness.wait { coordinator.status(for: directory) == .completed }
    #expect(await harness.service.uploadCount == 1)
  }

  // MARK: Failure handling

  @Test("a transient failure is retried without re-uploading")
  func retriesTransientFailure() async throws {
    let harness = try TranscriptionHarness()
    await harness.service.setCompletionErrors([TranscriptionError.serverError(503, "busy")])
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.transcribe(recordingDirectory: directory)
    await harness.wait { coordinator.status(for: directory) == .completed }

    #expect(await harness.service.completionCount == 2)
    #expect(await harness.service.uploadCount == 1)
    #expect(TranscriptDocument.load(for: directory) != nil)
  }

  @Test("a terminal failure surfaces the error and keeps the job for retry")
  func terminalFailureKeepsJob() async throws {
    let harness = try TranscriptionHarness()
    await harness.service.setUploadError(TranscriptionError.uploadFailed("invalid key"))
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.transcribe(recordingDirectory: directory)
    await harness.wait {
      if case .error = coordinator.status(for: directory) { return true }
      return false
    }

    #expect(coordinator.status(for: directory) == .error("Upload failed: invalid key"))
    #expect(TranscriptionJob.load(for: directory)?.lastError != nil)
    #expect(TranscriptDocument.load(for: directory) == nil)
    // One attempt only: an invalid key is not worth retrying.
    #expect(await harness.service.uploadCount == 1)
  }

  @Test("a terminal failure after upload drops the audio it left on the server")
  func terminalFailureDiscardsRemoteArtifacts() async throws {
    let harness = try TranscriptionHarness()
    await harness.service.setCompletionErrors([
      TranscriptionError.transcriptionFailed("unsupported audio")
    ])
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.transcribe(recordingDirectory: directory)
    await harness.wait { await harness.service.deletedFileIds.contains("file-1") }

    #expect(await harness.service.deletedTranscriptionIds == ["transcription-1"])
    // The failure is kept for the UI, but the ids are gone: a retry starts clean.
    let job = try #require(TranscriptionJob.load(for: directory))
    #expect(job.lastError != nil)
    #expect(job.fileId == nil)
    #expect(job.transcriptionId == nil)
  }

  @Test("retrying a failed job clears the recorded error")
  func retryClearsRecordedError() async throws {
    let harness = try TranscriptionHarness()
    await harness.service.setUploadError(TranscriptionError.uploadFailed("invalid key"))
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.transcribe(recordingDirectory: directory)
    await harness.wait {
      if case .error = coordinator.status(for: directory) { return true }
      return false
    }

    await harness.service.setUploadError(nil)
    coordinator.transcribe(recordingDirectory: directory)
    await harness.wait { coordinator.status(for: directory) == .completed }

    #expect(TranscriptDocument.load(for: directory) != nil)
    #expect(TranscriptionJob.load(for: directory) == nil)
  }

  @Test("cancelling drops the job and the remote artifacts")
  func cancelDropsJobAndRemoteArtifacts() async throws {
    let harness = try TranscriptionHarness()
    await harness.service.setHoldsCompletion(true)
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.transcribe(recordingDirectory: directory)
    await harness.wait { await harness.service.completionCount == 1 }

    coordinator.cancel(recordingDirectory: directory)
    await harness.wait { await harness.service.deletedFileIds.contains("file-1") }

    #expect(coordinator.status(for: directory) == .idle)
    #expect(TranscriptionJob.load(for: directory) == nil)
    #expect(await harness.service.deletedTranscriptionIds == ["transcription-1"])
  }

  @Test("cancelling a queued job drops the audio a previous session uploaded")
  func cancelQueuedJobDiscardsRemoteArtifacts() async throws {
    let harness = try TranscriptionHarness()
    await harness.service.setHoldsCompletion(true)
    let running = try harness.makeRecording("call-1")
    let queued = try harness.makeRecording("call-2")
    var job = TranscriptionJob()
    job.fileId = "file-from-previous-session"
    job.transcriptionId = "transcription-from-previous-session"
    job.save(for: queued)

    let coordinator = harness.makeCoordinator()
    coordinator.transcribe(recordingDirectory: running)
    await harness.wait { await harness.service.completionCount == 1 }
    coordinator.transcribe(recordingDirectory: queued)
    #expect(coordinator.status(for: queued) == .queued)

    coordinator.cancel(recordingDirectory: queued)
    await harness.wait {
      await harness.service.deletedFileIds.contains("file-from-previous-session")
    }

    #expect(TranscriptionJob.load(for: queued) == nil)
    #expect(coordinator.status(for: queued) == .idle)
  }

  // MARK: Resume

  @Test("a job interrupted mid-poll resumes without re-uploading")
  func resumesInterruptedJob() async throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    var job = TranscriptionJob()
    job.fileId = "file-from-previous-session"
    job.transcriptionId = "transcription-from-previous-session"
    job.save(for: directory)

    let coordinator = harness.makeCoordinator()
    coordinator.resumePendingJobs()
    await harness.wait { coordinator.status(for: directory) == .completed }

    #expect(await harness.service.uploadCount == 0)
    #expect(await harness.service.createCount == 0)
    #expect(await harness.service.completionCount == 1)
    #expect(TranscriptDocument.load(for: directory) != nil)
  }

  @Test("a job that already failed is surfaced, not retried, on launch")
  func doesNotAutoRetryFailedJobOnLaunch() async throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    var job = TranscriptionJob()
    job.lastError = "Upload failed: invalid key"
    job.save(for: directory)

    let coordinator = harness.makeCoordinator()
    coordinator.resumePendingJobs()
    await harness.wait {
      if case .error = coordinator.status(for: directory) { return true }
      return false
    }

    #expect(coordinator.status(for: directory) == .error("Upload failed: invalid key"))
    #expect(await harness.service.uploadCount == 0)
  }

  @Test("turning the setting off stops a pending auto job that never uploaded")
  func dropsPendingAutoJobWhenSettingTurnedOff() async throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    // What the quit path leaves behind: enqueued, nothing uploaded yet.
    TranscriptionJob(isAutomatic: true).save(for: directory)
    harness.autoEnabled = false

    let coordinator = harness.makeCoordinator()
    coordinator.resumePendingJobs()
    await harness.wait { TranscriptionJob.load(for: directory) == nil }

    #expect(await harness.service.uploadCount == 0)
    #expect(TranscriptionJob.load(for: directory) == nil)
  }

  @Test("an auto job that already uploaded still finishes with the setting off")
  func finishesUploadedAutoJobWhenSettingTurnedOff() async throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    var job = TranscriptionJob(isAutomatic: true)
    job.fileId = "file-from-previous-session"
    job.save(for: directory)
    harness.autoEnabled = false

    let coordinator = harness.makeCoordinator()
    coordinator.resumePendingJobs()
    await harness.wait { coordinator.status(for: directory) == .completed }

    // Finishing beats stranding the audio on Soniox, so this one runs anyway.
    #expect(await harness.service.uploadCount == 0)
    #expect(TranscriptDocument.load(for: directory) != nil)
  }

  @Test("a manual job resumes regardless of the auto-transcribe setting")
  func resumesManualJobWithSettingOff() async throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    TranscriptionJob(isAutomatic: false).save(for: directory)
    harness.autoEnabled = false

    let coordinator = harness.makeCoordinator()
    coordinator.resumePendingJobs()
    await harness.wait { coordinator.status(for: directory) == .completed }

    #expect(await harness.service.uploadCount == 1)
  }

  @Test("nothing resumes without an API key")
  func skipsResumeWithoutAPIKey() async throws {
    let harness = try TranscriptionHarness()
    harness.apiKey = nil
    let directory = try harness.makeRecording("call-1")
    TranscriptionJob().save(for: directory)

    let coordinator = harness.makeCoordinator()
    coordinator.resumePendingJobs()
    await harness.wait(upTo: 0.2) { await harness.service.uploadCount > 0 }

    #expect(await harness.service.uploadCount == 0)
    #expect(TranscriptionJob.load(for: directory) != nil)
  }

  @Test("a recording whose audio is gone drops its job instead of looping")
  func dropsJobWhenAudioMissing() async throws {
    let harness = try TranscriptionHarness()
    let directory = harness.root.appendingPathComponent("call-1")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    TranscriptionJob().save(for: directory)

    let coordinator = harness.makeCoordinator()
    coordinator.resumePendingJobs()
    await harness.wait { TranscriptionJob.load(for: directory) == nil }

    #expect(TranscriptionJob.load(for: directory) == nil)
    #expect(await harness.service.uploadCount == 0)
  }
}
