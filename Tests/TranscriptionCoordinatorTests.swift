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

  /// Runs just before `upload` returns, so a test can model the user changing
  /// something during the longest await in the job.
  private var afterUpload: (@Sendable () async -> Void)?

  func setUploadError(_ error: Error?) { uploadError = error }
  func setCompletionErrors(_ errors: [Error]) { completionErrors = errors }
  func setHoldsCompletion(_ holds: Bool) { holdsCompletion = holds }
  func setAfterUpload(_ handler: (@Sendable () async -> Void)?) { afterUpload = handler }

  private var holdsUpload = false
  private(set) var uploadsInFlight = 0
  private(set) var maxConcurrentUploads = 0

  func setHoldsUpload(_ holds: Bool) { holdsUpload = holds }

  func upload(
    fileURL: URL,
    onProgress: @escaping @Sendable (TranscriptionUploadPhase) -> Void
  ) async throws -> String {
    uploadCount += 1
    if let uploadError { throw uploadError }
    uploadsInFlight += 1
    maxConcurrentUploads = max(maxConcurrentUploads, uploadsInFlight)
    defer { uploadsInFlight -= 1 }
    // Reported so a test can observe the coordinator's stage transitions
    // rather than only its terminal states.
    onProgress(.mixing(1))
    onProgress(.uploading(0.5))
    // Held so a test can pin jobs inside the stage the upload gate bounds.
    while holdsUpload {
      try? await Task.sleep(for: .milliseconds(2))
      try Task.checkCancellation()
    }
    await afterUpload?()
    onProgress(.uploading(1))
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
  /// Long enough to clear the automatic-transcription duration floor. Tests that
  /// care about the floor set it explicitly.
  var duration: Double? = 600
  /// Backoff and gate waits are no-ops by default so retries resolve instantly.
  /// Captured by value in `makeCoordinator`, unlike every other knob here, so
  /// set it BEFORE calling `makeCoordinator()` - a later assignment is ignored.
  var sleepHandler: @Sendable (Duration) async -> Void = { _ in }
  /// Runs where the real temp-file sweep runs, inside `resumePendingJobs` and
  /// before its scan. Lets a test act on a recording in that window.
  var sweepHandler: (@Sendable () async -> Void)?
  /// Captured by value in `makeCoordinator`, like `sleepHandler` - set it
  /// before building the coordinator.
  var uploadConcurrency = 2

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
        sleep: { [sleepHandler] duration in await sleepHandler(duration) },
        durationSeconds: { [weak self] _ in await self?.duration },
        sweepTemporaryFiles: { [weak self] in await self?.sweepHandler?() },
        uploadConcurrency: uploadConcurrency
      ))
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

    coordinator.recordingFinished(recordingDirectory: directory)
    await harness.wait { coordinator.status(for: directory) == .completed }
    // Cleanup is deliberately fire-and-forget so cancellation cannot kill it,
    // which means it lands after `.completed` rather than before.
    await harness.wait { await harness.service.deletedFileIds == ["file-1"] }

    #expect(coordinator.status(for: directory) == .completed)
    #expect(TranscriptDocument.load(for: directory)?.segments.count == 1)
    #expect(await harness.service.uploadCount == 1)
    // The job sidecar exists only while work is outstanding.
    #expect(TranscriptionJob.load(for: directory) == nil)
    #expect(await harness.service.deletedFileIds == ["file-1"])
    #expect(await harness.service.deletedTranscriptionIds == ["transcription-1"])
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

    coordinator.recordingFinished(recordingDirectory: directory)
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

    coordinator.recordingFinished(recordingDirectory: directory)
    await harness.wait(upTo: 0.2) { await harness.service.uploadCount > 0 }

    #expect(await harness.service.uploadCount == 0)
    #expect(!coordinator.hasAPIKey)
    #expect(TranscriptionJob.load(for: directory) == nil)
  }

  /// The save directory holds every recording and, on an old install, stray
  /// loose audio next to them. Enqueueing it transcribes whichever stray file
  /// `RecordingStore.audioURL(in:)` finds and bills the user for it, so a
  /// directory that is not a child of the save directory is refused outright.
  @Test("refuses a directory that is not a recording directory")
  func refusesNonRecordingDirectory() async throws {
    let harness = try TranscriptionHarness()
    try harness.makeRecording("call-1")
    let strayAudio = harness.root.appendingPathComponent("audio.m4a")
    try Data([0]).write(to: strayAudio)
    let coordinator = harness.makeCoordinator()

    coordinator.recordingFinished(recordingDirectory: harness.root)
    await harness.wait(upTo: 0.2) { await harness.service.uploadCount > 0 }

    #expect(await harness.service.uploadCount == 0)
    #expect(coordinator.status(for: harness.root) == .idle)
    #expect(TranscriptionJob.load(for: harness.root) == nil)
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

  /// The direct regression test for the reported bug: a recording finished at
  /// 17:52 did not start transcribing until 18:17, because it sat behind
  /// another job's poll loop.
  @Test("a second recording transcribes while the first is still polling")
  func jobsRunConcurrently() async throws {
    let harness = try TranscriptionHarness()
    await harness.service.setHoldsCompletion(true)
    let first = try harness.makeRecording("call-1")
    let second = try harness.makeRecording("call-2")
    let coordinator = harness.makeCoordinator()

    coordinator.transcribe(recordingDirectory: first)
    // Wait until the first job is inside `awaitCompletion` before releasing the
    // hold - it is a single flag on the fake, read at call time, so the first
    // job stays parked while later ones sail past.
    await harness.wait { coordinator.status(for: first) == .transcribing }
    await harness.service.setHoldsCompletion(false)
    coordinator.transcribe(recordingDirectory: second)

    // The second job runs to completion while the first is still parked in
    // `awaitCompletion`, which is where a job spends most of its life.
    await harness.wait { coordinator.status(for: second) == .completed }
    #expect(coordinator.status(for: second) == .completed)
    #expect(await harness.service.uploadCount == 2)
    #expect(coordinator.status(for: first) == .transcribing)

    coordinator.cancel(recordingDirectory: first)
  }

  @Test("cancelling one job leaves the others running")
  func cancellingOneJobLeavesOthers() async throws {
    let harness = try TranscriptionHarness()
    await harness.service.setHoldsCompletion(true)
    let first = try harness.makeRecording("call-1")
    let second = try harness.makeRecording("call-2")
    let coordinator = harness.makeCoordinator()

    coordinator.transcribe(recordingDirectory: first)
    await harness.wait { coordinator.status(for: first) == .transcribing }
    await harness.service.setHoldsCompletion(false)
    coordinator.transcribe(recordingDirectory: second)

    coordinator.cancel(recordingDirectory: first)
    await harness.wait { coordinator.status(for: second) == .completed }

    #expect(coordinator.status(for: second) == .completed)
    #expect(coordinator.status(for: first) == .idle)
    #expect(TranscriptDocument.load(for: second) != nil)
  }

  @Test("resume starts every pending job, not just the first")
  func resumeStartsEveryJob() async throws {
    let harness = try TranscriptionHarness()
    for name in ["call-1", "call-2", "call-3"] {
      let directory = try harness.makeRecording(name)
      TranscriptionJob(fileId: "f", transcriptionId: "t", isAutomatic: false)
        .save(for: directory)
    }
    let coordinator = harness.makeCoordinator()

    coordinator.resumePendingJobs()
    await harness.wait { await harness.service.completionCount == 3 }

    #expect(await harness.service.completionCount == 3)
  }

  @Test("at most the configured number of uploads run at once")
  func uploadConcurrencyIsBounded() async throws {
    let harness = try TranscriptionHarness()
    harness.uploadConcurrency = 2
    await harness.service.setHoldsUpload(true)
    let directories = try (1...5).map { try harness.makeRecording("call-\($0)") }
    let coordinator = harness.makeCoordinator()

    for directory in directories { coordinator.transcribe(recordingDirectory: directory) }
    await harness.wait { await harness.service.uploadsInFlight == 2 }
    #expect(await harness.service.uploadsInFlight == 2)

    await harness.service.setHoldsUpload(false)
    await harness.wait { coordinator.status(for: directories[4]) == .completed }

    #expect(await harness.service.maxConcurrentUploads <= 2)
    #expect(await harness.service.uploadCount == 5)
  }

  @Test("a job waiting for an upload slot is dropped when consent is withdrawn")
  func consentWithdrawnWhileWaitingForSlot() async throws {
    let harness = try TranscriptionHarness()
    harness.uploadConcurrency = 1
    await harness.service.setHoldsUpload(true)
    let first = try harness.makeRecording("call-1")
    let second = try harness.makeRecording("call-2")
    let coordinator = harness.makeCoordinator()

    coordinator.recordingFinished(recordingDirectory: first)
    await harness.wait { await harness.service.uploadsInFlight == 1 }
    coordinator.recordingFinished(recordingDirectory: second)

    // The second job is parked on the gate, which is a wait the user can act
    // during - so it has to be a consent re-check point like every other wait.
    harness.autoEnabled = false
    await harness.service.setHoldsUpload(false)
    await harness.wait { TranscriptionJob.load(for: second) == nil }

    #expect(coordinator.status(for: second) == .idle)
    #expect(await harness.service.uploadCount == 1)
  }

  @Test("two jobs finishing back to back each report their own completion")
  func finishCountsArePerRecording() async throws {
    let harness = try TranscriptionHarness()
    let first = try harness.makeRecording("call-1")
    let second = try harness.makeRecording("call-2")
    let coordinator = harness.makeCoordinator()

    coordinator.transcribe(recordingDirectory: first)
    coordinator.transcribe(recordingDirectory: second)
    await harness.wait {
      coordinator.status(for: first) == .completed && coordinator.status(for: second) == .completed
    }

    // A single `lastFinishedPath` could only name one of these, so an open
    // detail view on the other never reloaded its transcript.
    #expect(coordinator.finishCount(for: first) == 1)
    #expect(coordinator.finishCount(for: second) == 1)
  }

  @Test("a recording reported at quit writes its sidecar without starting")
  func quitDefersInsteadOfUploading() async throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.suspendNewJobs()
    coordinator.recordingFinished(recordingDirectory: directory)
    await harness.wait(upTo: 0.2) { await harness.service.uploadCount > 0 }

    #expect(await harness.service.uploadCount == 0)
    #expect(TranscriptionJob.load(for: directory) != nil)

    // The next launch picks it up, which is the whole point of deferring rather
    // than starting an upload the process kill is about to interrupt.
    let next = harness.makeCoordinator()
    next.resumePendingJobs()
    await harness.wait { next.status(for: directory) == .completed }
    #expect(next.status(for: directory) == .completed)
  }

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
    // Resume polls the id it already had and fetches once; it does not re-create.
    #expect(await harness.service.fetchCount == 1)
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

  @Test("an auto job that uploaded but was never billed is dropped with the setting off")
  func dropsUploadedButUnbilledAutoJobWhenSettingTurnedOff() async throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    var job = TranscriptionJob(isAutomatic: true)
    job.fileId = "file-from-previous-session"
    job.save(for: directory)
    harness.autoEnabled = false

    let coordinator = harness.makeCoordinator()
    coordinator.resumePendingJobs()
    await harness.wait {
      await harness.service.deletedFileIds.contains("file-from-previous-session")
    }

    // Consent was withdrawn before anything was charged, so the right move is to
    // delete the uploaded audio rather than bill for a transcription of it.
    #expect(await harness.service.createCount == 0)
    #expect(TranscriptionJob.load(for: directory) == nil)
    #expect(TranscriptDocument.load(for: directory) == nil)
  }

  @Test("an auto job that was already billed still finishes with the setting off")
  func finishesBilledAutoJobWhenSettingTurnedOff() async throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    var job = TranscriptionJob(isAutomatic: true)
    job.fileId = "file-from-previous-session"
    job.transcriptionId = "transcription-from-previous-session"
    job.save(for: directory)
    harness.autoEnabled = false

    let coordinator = harness.makeCoordinator()
    coordinator.resumePendingJobs()
    await harness.wait { coordinator.status(for: directory) == .completed }

    // The money is already spent; throwing the result away helps nobody.
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

  @Test("a job whose audio is gone deletes what it had already uploaded")
  func dropsJobWhenAudioMissingDiscardsRemoteArtifacts() async throws {
    let harness = try TranscriptionHarness()
    let directory = harness.root.appendingPathComponent("call-1")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var job = TranscriptionJob()
    job.fileId = "file-from-previous-session"
    job.transcriptionId = "transcription-from-previous-session"
    job.save(for: directory)

    let coordinator = harness.makeCoordinator()
    coordinator.resumePendingJobs()
    await harness.wait {
      await harness.service.deletedFileIds.contains("file-from-previous-session")
    }

    // Removing the sidecar without this would destroy the only record of what
    // is sitting on Soniox.
    #expect(
      await harness.service.deletedTranscriptionIds == ["transcription-from-previous-session"])
    #expect(TranscriptionJob.load(for: directory) == nil)
  }

  // MARK: Consent re-checks

  @Test("a queued auto job does not upload if the setting is turned off first")
  func dropsQueuedAutoJobWhenSettingTurnedOffBeforeItRuns() async throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.recordingFinished(recordingDirectory: directory)
    // No await between the enqueue and the flip, so the job's task cannot have
    // run yet - this is the window between queueing and first execution.
    #expect(coordinator.status(for: directory) == .queued)

    // The user changes their mind before the job gets going.
    harness.autoEnabled = false
    await harness.wait { TranscriptionJob.load(for: directory) == nil }

    #expect(await harness.service.uploadCount == 0)
    #expect(coordinator.status(for: directory) == .idle)
  }

  @Test("a manual request outranks the automatic flag an interrupted job left behind")
  func manualEnqueueDowngradesAutomaticFlag() async throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    // An automatic job is enqueued...
    coordinator.recordingFinished(recordingDirectory: directory)
    #expect(TranscriptionJob.load(for: directory)?.isAutomatic == true)

    // ...then, in the same main-actor turn and so before that job's task has
    // run, the user asks for the same recording explicitly and turns the
    // setting off. The downgrade must survive, or the job would be dropped as
    // a withdrawn automatic one.
    coordinator.transcribe(recordingDirectory: directory)
    #expect(TranscriptionJob.load(for: directory)?.isAutomatic == false)

    harness.autoEnabled = false
    await harness.wait { coordinator.status(for: directory) == .completed }

    #expect(await harness.service.uploadCount == 1)
  }

  @Test("consent withdrawn during a retry wait stops the job before it bills")
  func dropsInFlightAutoJobWhenSettingTurnedOffDuringBackoff() async throws {
    let harness = try TranscriptionHarness()
    await harness.service.setUploadError(TranscriptionError.serverError(503, "busy"))
    // The user reaches Settings while the job is sleeping off a transient error.
    harness.sleepHandler = { [weak harness] _ in
      await MainActor.run { harness?.autoEnabled = false }
    }
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.recordingFinished(recordingDirectory: directory)
    await harness.wait { TranscriptionJob.load(for: directory) == nil }

    // The retry that would have followed the wait never runs.
    #expect(await harness.service.uploadCount == 1)
    #expect(await harness.service.createCount == 0)
    #expect(coordinator.status(for: directory) == .idle)
  }

  @Test("consent withdrawn during the upload stops the job before it bills")
  func dropsAutoJobWhenSettingTurnedOffDuringUpload() async throws {
    let harness = try TranscriptionHarness()
    // Uploading a long call re-encodes and transmits the whole recording, so
    // this window is minutes wide in practice.
    await harness.service.setAfterUpload { [weak harness] in
      await MainActor.run { harness?.autoEnabled = false }
    }
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.recordingFinished(recordingDirectory: directory)
    await harness.wait { TranscriptionJob.load(for: directory) == nil }

    #expect(await harness.service.uploadCount == 1)
    // The billing call never goes out, and the upload is deleted again.
    #expect(await harness.service.createCount == 0)
    #expect(await harness.service.deletedFileIds == ["file-1"])
  }

  // MARK: Sidecar format

  @Test("a job sidecar written before a field existed still decodes")
  func decodesSidecarMissingNewerFields() throws {
    // Exactly what an earlier build wrote. The synthesized decoder throws on a
    // missing key, and `load` swallows that with `try?`, so getting this wrong
    // orphans in-flight jobs and strands their audio on Soniox.
    let legacy = #"{"attempts":2,"fileId":"file-1","transcriptionId":"transcription-1"}"#
    let job = try #require(
      try? JSONDecoder().decode(TranscriptionJob.self, from: Data(legacy.utf8)))

    #expect(job.fileId == "file-1")
    #expect(job.transcriptionId == "transcription-1")
    #expect(job.attempts == 2)
    #expect(job.isAutomatic == false)
    #expect(job.lastError == nil)
    #expect(job.awaitingRemoteDelete == false)
  }

  @Test("an empty job sidecar decodes to a clean job rather than being dropped")
  func decodesEmptySidecar() throws {
    let job = try #require(try? JSONDecoder().decode(TranscriptionJob.self, from: Data("{}".utf8)))

    #expect(job.fileId == nil)
    #expect(job.attempts == 0)
    #expect(job.awaitingRemoteDelete == false)
  }

  // MARK: Cleanup that cannot run

  @Test("cleanup that cannot run without a key is kept and retried at next launch")
  func keepsDeleteOnlyRecordWhenKeyIsMissing() async throws {
    let harness = try TranscriptionHarness()
    await harness.service.setHoldsCompletion(true)
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.transcribe(recordingDirectory: directory)
    await harness.wait { await harness.service.completionCount == 1 }

    // The user clears the key mid-job, then cancels the recording.
    harness.apiKey = nil
    coordinator.apiKeyChanged()
    coordinator.cancel(recordingDirectory: directory)
    await harness.wait { TranscriptionJob.load(for: directory)?.awaitingRemoteDelete == true }

    // Nothing could be deleted, so the ids are still on disk rather than lost.
    #expect(await harness.service.deletedFileIds.isEmpty)
    let kept = try #require(TranscriptionJob.load(for: directory))
    #expect(kept.fileId == "file-1")
    #expect(kept.transcriptionId == "transcription-1")

    // With the key back, the next launch finishes the cleanup and does not
    // re-run the job itself.
    harness.apiKey = "test-key"
    let relaunched = harness.makeCoordinator()
    relaunched.resumePendingJobs()
    await harness.wait { await harness.service.deletedFileIds.contains("file-1") }

    #expect(TranscriptionJob.load(for: directory) == nil)
    #expect(await harness.service.uploadCount == 1)
    #expect(await harness.service.createCount == 1)
  }

  @Test("a terminal failure that could not clean up keeps its ids and cleans up later")
  func terminalFailureWithoutKeyKeepsIdsAndCleansUpAtNextLaunch() async throws {
    let harness = try TranscriptionHarness()
    await harness.service.setCompletionErrors([
      TranscriptionError.transcriptionFailed("unsupported audio")
    ])
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()
    // The key goes away between the upload and the failure, so the cleanup the
    // failure would normally do cannot be dispatched. `apiKeyChanged` is what
    // Settings calls on the same edit; without it the coordinator keeps serving
    // the key it cached when the job started.
    await harness.service.setAfterUpload { [weak harness, weak coordinator] in
      await MainActor.run {
        harness?.apiKey = nil
        coordinator?.apiKeyChanged()
      }
    }

    coordinator.transcribe(recordingDirectory: directory)
    await harness.wait { TranscriptionJob.load(for: directory)?.lastError != nil }

    // The ids survive: they are the only record of what is on Soniox.
    let failed = try #require(TranscriptionJob.load(for: directory))
    #expect(failed.fileId == "file-1")
    #expect(await harness.service.deletedFileIds.isEmpty)

    harness.apiKey = "test-key"
    let relaunched = harness.makeCoordinator()
    relaunched.resumePendingJobs()
    await harness.wait { await harness.service.deletedFileIds.contains("file-1") }

    // The failure is still on screen for the user to retry, but the artifacts
    // are gone and the record no longer names them.
    let cleaned = try #require(TranscriptionJob.load(for: directory))
    #expect(cleaned.lastError != nil)
    #expect(cleaned.fileId == nil)
    #expect(cleaned.transcriptionId == nil)
    #expect(await harness.service.uploadCount == 1)
  }

  @Test("transcribing a recording with leftover cleanup starts clean instead of reusing its ids")
  func manualTranscribeClearsDeleteOnlyRecord() async throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    // What a cancel with no key leaves behind.
    TranscriptionJob(
      fileId: "stale-file", transcriptionId: "stale-transcription", awaitingRemoteDelete: true
    ).save(for: directory)
    let coordinator = harness.makeCoordinator()

    coordinator.transcribe(recordingDirectory: directory)
    await harness.wait { coordinator.status(for: directory) == .completed }

    // The leftovers are deleted, and the new job uploaded rather than polling
    // the transcription id it was in the middle of deleting.
    #expect(await harness.service.deletedFileIds.contains("stale-file"))
    #expect(await harness.service.uploadCount == 1)
    #expect(await harness.service.createCount == 1)
    #expect(TranscriptionJob.load(for: directory) == nil)
  }

  /// A control, not a regression test: it holds with the stale-snapshot version
  /// too. The window the fix closes is a single continuation hop inside the
  /// off-main scan, which no test can land in deterministically without a seam
  /// that would dictate the snapshot and make the test circular. What this does
  /// pin is that acting on a recording while resume is running leaves the
  /// user's job intact.
  @Test("resume leaves alone a job the user restarted while it was scanning")
  func resumeSkipsJobsAlreadyInFlight() async throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    // A failure from a previous session whose cleanup could not be dispatched,
    // so it still holds the ids naming what is on Soniox.
    TranscriptionJob(
      fileId: "file-from-previous-session",
      transcriptionId: "transcription-from-previous-session",
      lastError: "Soniox error 503: busy"
    ).save(for: directory)
    let coordinator = harness.makeCoordinator()
    // Retry lands inside the window between resume starting and its scan
    // reading the record - which is where the real sweep enumerates and
    // deletes recording-sized scratch files, so it is not a microsecond wide.
    harness.sweepHandler = { [weak coordinator] in
      await MainActor.run { coordinator?.transcribe(recordingDirectory: directory) }
    }

    coordinator.resumePendingJobs()
    await harness.wait { coordinator.status(for: directory) == .completed }

    // The user's retry ran to completion: resume neither cancelled it nor wrote
    // the old failed record back over it.
    #expect(TranscriptDocument.load(for: directory) != nil)
    #expect(TranscriptionJob.load(for: directory) == nil)
    // It started clean rather than re-polling a transcription that had already
    // failed, and the leftovers from the previous session were deleted.
    #expect(await harness.service.uploadCount == 1)
    #expect(await harness.service.createCount == 1)
    #expect(
      await harness.service.deletedTranscriptionIds.contains(
        "transcription-from-previous-session"))
  }

  // MARK: Minimum duration

  @Test("an automatic job is dropped when the recording is too short to be a call")
  func dropsAutomaticJobBelowDurationFloor() async throws {
    let harness = try TranscriptionHarness()
    harness.duration = 1.5
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.recordingFinished(recordingDirectory: directory)
    await harness.wait { TranscriptionJob.load(for: directory) == nil }

    #expect(await harness.service.uploadCount == 0)
    #expect(coordinator.status(for: directory) == .idle)
  }

  @Test("an automatic job is dropped when the duration cannot be read at all")
  func dropsAutomaticJobWithUnreadableDuration() async throws {
    let harness = try TranscriptionHarness()
    // What a recorder that died on startup leaves behind: a container that will
    // not open. The floor has to fail closed here, not wave it through.
    harness.duration = nil
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.recordingFinished(recordingDirectory: directory)
    await harness.wait { TranscriptionJob.load(for: directory) == nil }

    #expect(await harness.service.uploadCount == 0)
    #expect(coordinator.status(for: directory) == .idle)
  }

  /// A control, not a regression test: it holds with the floor removed entirely,
  /// because it asserts the absence of a behaviour. It catches an inverted
  /// comparison, not a missing floor.
  @Test("a manual job is transcribed however short the recording is")
  func manualJobIgnoresDurationFloor() async throws {
    let harness = try TranscriptionHarness()
    harness.duration = 1.5
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.transcribe(recordingDirectory: directory)
    await harness.wait { coordinator.status(for: directory) == .completed }

    #expect(await harness.service.uploadCount == 1)
  }

  /// Also a control, for the same reason as the test above.
  @Test("an automatic job runs when the recording is long enough")
  func runsAutomaticJobAboveDurationFloor() async throws {
    let harness = try TranscriptionHarness()
    harness.duration = 42
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.recordingFinished(recordingDirectory: directory)
    await harness.wait { coordinator.status(for: directory) == .completed }

    #expect(await harness.service.uploadCount == 1)
  }
}
