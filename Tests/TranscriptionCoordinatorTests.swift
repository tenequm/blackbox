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
    tokens: [TranscriptToken(text: "hello", startMs: 0, endMs: 500, speaker: 1)],
    language: "en", createdAt: Date(timeIntervalSince1970: 1_700_000_000)
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

  /// Keeps the job parked even after it is cancelled, so a test can observe
  /// what happens to a cancelled-but-still-running job. Real uploads behave
  /// this way: cancellation is only noticed at a suspension point, and
  /// `URLSession` does not abandon a transmit mid-flight.
  private var holdIgnoresCancellation = false
  func setHoldIgnoresCancellation(_ ignores: Bool) { holdIgnoresCancellation = ignores }

  /// Kept so a test can fire a progress report at a moment of its choosing.
  /// The scripted reports below all land before the hold, and the hold loop
  /// throws on cancellation, so there is otherwise no way to model a report
  /// arriving *after* the user pressed Cancel - which is the case that matters.
  private var progressHandler: (@Sendable (TranscriptionUploadPhase) -> Void)?
  func emitProgress(_ phase: TranscriptionUploadPhase) { progressHandler?(phase) }

  func upload(
    fileURL: URL,
    onProgress: @escaping @Sendable (TranscriptionUploadPhase) -> Void
  ) async throws -> String {
    progressHandler = onProgress
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
      if !holdIgnoresCancellation { try Task.checkCancellation() }
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

  /// Settable so a test can hold the coordinator in the state a failed cleanup
  /// leaves it in: the record kept, the ids still naming what is on Soniox.
  var deleteSucceeds = true

  func deleteRemote(transcriptionIds: [String], fileIds: [String]) async -> Bool {
    deletedTranscriptionIds.append(contentsOf: transcriptionIds)
    deletedFileIds.append(contentsOf: fileIds)
    return deleteSucceeds
  }

  func setDeleteSucceeds(_ value: Bool) { deleteSucceeds = value }
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
  let defaults: UserDefaults
  var sleepForAttributionDeadline = TranscriptionCoordinator.Dependencies()
    .sleepForAttributionDeadline
  var micEnabled = false
  var analyzeMic: @Sendable (URL, [TranscriptToken]) async throws -> SpeakerAttribution? = {
    _, _ in
    Issue.record("Unexpected attribution")
    return nil
  }
  var saveProjectedTranscript: (TranscriptDocument.Encoded, URL) throws -> Void = TranscriptDocument
    .save
  /// Recordings the coordinator handed to the after-transcript hook, and whether
  /// each one's transcript was already on disk at that moment.
  var hookedDirectories: [URL] = []
  var transcriptOnDiskAtHook: [Bool] = []
  var speakersAtHook: [[Int]] = []
  var textAtHook: [String] = []

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("blackbox-transcription-\(UUID().uuidString)")
    defaults = UserDefaults(suiteName: root.lastPathComponent)!
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  deinit {
    UserDefaults.standard.removePersistentDomain(forName: root.lastPathComponent)
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
        uploadConcurrency: uploadConcurrency,
        isMicAttributionEnabled: { [weak self] in self?.micEnabled == true },
        analyzeMic: analyzeMic, defaults: defaults,
        sleepForAttributionDeadline: sleepForAttributionDeadline,
        saveProjectedTranscript: saveProjectedTranscript,
        onTranscriptSaved: { [weak self] directory in
          self?.hookedDirectories.append(directory)
          let transcript = TranscriptDocument.load(for: directory)
          self?.transcriptOnDiskAtHook.append(transcript != nil)
          self?.speakersAtHook.append(transcript?.segments.map(\.speaker) ?? [])
          self?.textAtHook.append(
            (try? String(
              contentsOf: TranscriptDocument.plainTextURL(for: directory), encoding: .utf8)) ?? "")
        }
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

  @Test("the after-transcript hook fires once, only after the transcript is on disk")
  func hookFiresAfterSave() async throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.transcribe(recordingDirectory: directory)
    await harness.wait { coordinator.status(for: directory) == .completed }

    #expect(harness.hookedDirectories == [directory])
    #expect(harness.transcriptOnDiskAtHook == [true])
  }

  @Test("a failed transcription never fires the hook")
  func hookSkipsFailures() async throws {
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

    #expect(harness.hookedDirectories.isEmpty)
  }

  @Test("the hook command gets the recording through its environment and logs to hook.log")
  func hookRunsCommandWithEnvironment() async throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    let script = harness.root.appendingPathComponent("hook.sh")
    let id = TranscriptHook.recordingIDVariable
    let dir = TranscriptHook.recordingDirectoryVariable
    try "#!/bin/sh\necho \"id=$\(id) dir=$\(dir)\"\n"
      .write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

    TranscriptHook.run(for: directory, path: script.path)

    let log = directory.appendingPathComponent(TranscriptHook.logFileName)
    await harness.wait {
      ((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains("dir=")
    }
    let output = try String(contentsOf: log, encoding: .utf8)
    #expect(output.contains("id=call-1 dir=\(directory.path)"))
  }

  @Test("a blank, missing, non-executable or directory hook path runs nothing")
  func hookIgnoresBadPaths() throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    let plain = harness.root.appendingPathComponent("plain.sh")
    try "#!/bin/sh\necho ran\n".write(to: plain, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plain.path)
    for path in [
      "  ", harness.root.appendingPathComponent("missing").path, plain.path, harness.root.path,
    ] {
      #expect(TranscriptHook.executableURL(for: path) == nil, "\(path)")
      TranscriptHook.run(for: directory, path: path)
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: directory.appendingPathComponent(TranscriptHook.logFileName).path))
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

    coordinator.prepareForTermination()
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
    // The record is retired on the delete's confirmation, one hop after the
    // status lands.
    await harness.wait { TranscriptionJob.load(for: directory) == nil }
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

  @Test func uploadedFileIDAndSourceArePersistedTogether() async throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call")
    let coordinator = harness.makeCoordinator()
    await harness.service.setHoldsUpload(true)
    await harness.service.setHoldsCompletion(true)
    coordinator.recordingFinished(recordingDirectory: directory)
    await harness.wait { await harness.service.uploadCount == 1 }
    let uploading = try #require(TranscriptionJob.load(for: directory))
    #expect(uploading.fileId == nil && uploading.sourceAudio == nil)
    await harness.service.setHoldsUpload(false)
    await harness.wait { await harness.service.completionCount == 1 }
    let uploaded = try #require(TranscriptionJob.load(for: directory))
    #expect(uploaded.fileId == "file-1" && uploaded.sourceAudio == RecordingStore.audioName)
    coordinator.cancel(recordingDirectory: directory)
    await harness.wait { TranscriptionJob.load(for: directory) == nil }
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

  /// The job sidecar was hardened against this and these two were not, which is
  /// worse: the three rename paths rebuild metadata from
  /// `load(...) ?? RecordingMetadata(fresh)` and write it back, so one
  /// unreadable decode plus one rename permanently loses the title, the date and
  /// every speaker name.
  @Test("a metadata file written before a field existed still decodes")
  func metadataDecodesWithMissingKeys() throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    let json = #"{"title":"Standup","appName":"Zoom"}"#
    try Data(json.utf8).write(to: directory.appendingPathComponent(RecordingMetadata.fileName))

    let loaded = try #require(RecordingMetadata.load(in: directory))
    #expect(loaded.title == "Standup")
    #expect(loaded.appName == "Zoom")
    #expect(loaded.speakers.isEmpty)
    #expect(loaded.windowTitles == nil)
  }

  @Test("a malformed window title loses only the title history")
  func metadataSurvivesMalformedWindowTitle() throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    let json = #"{"title":"Standup","speakers":{"0":"Alex"},"windowTitles":[{"at":1,"title":42}]}"#
    try Data(json.utf8).write(to: directory.appendingPathComponent(RecordingMetadata.fileName))
    let metadata = try #require(RecordingMetadata.load(in: directory))
    #expect(metadata.title == "Standup")
    #expect(metadata.speakers == ["0": "Alex"])
    #expect(metadata.windowTitles == nil)
  }

  @Test("saving a transcript writes and replaces the readable companion")
  func savesPlainTextTranscript() throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    try RecordingMetadata(
      title: "Standup", createdAt: Date(timeIntervalSince1970: 0), appName: "Meet",
      speakers: ["0": "Alex"]
    )
    .save(in: directory)
    var document = TranscriptDocument(
      segments: [
        TranscriptSegment(speaker: TranscriptSegment.localSpeaker, time: 0.92, text: "Hello"),
        TranscriptSegment(speaker: 0, time: 3605.9, text: "Hi\r\nthere"),
      ], language: "en", createdAt: Date(), provider: "Test Provider", model: "test-model")
    try document.save(for: directory)

    let url = TranscriptDocument.plainTextURL(for: directory)
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(
      text == """
        # Recording: call-1
        # App: Meet
        # Start (UTC): 1970-01-01T00:00:00Z
        # Test Provider model: test-model
        # Language: en

        [0:00] You: Hello
        [1:00:05] Alex: Hi there

        """)

    document.segments = [TranscriptSegment(speaker: 2, time: 66.3, text: "Replacement")]
    try document.save(for: directory)
    #expect(
      try String(contentsOf: url, encoding: .utf8) == text.components(separatedBy: "[0:00]")[0]
        + "[1:06] Speaker 3: Replacement\n")
    #expect(TranscriptDocument.load(for: directory)?.segments.map(\.text) == ["Replacement"])
  }

  @Test("a JSON write failure preserves the text companion and reports the JSON path")
  func jsonWriteFailurePreservesText() throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    let textURL = TranscriptDocument.plainTextURL(for: directory)
    let original = Data("previous transcript".utf8)
    try original.write(to: textURL)
    let jsonURL = TranscriptDocument.sidecarURL(for: directory)
    try FileManager.default.createDirectory(at: jsonURL, withIntermediateDirectories: false)
    let document = TranscriptDocument(segments: [], createdAt: Date())
    #expect {
      try document.save(for: directory)
    } throws: { error in
      (error as? CocoaError)?.filePath == jsonURL.path
    }
    #expect(try Data(contentsOf: textURL) == original)
  }

  @Test("a text write failure keeps the updated JSON and removes the failed companion")
  func textWriteFailurePreservesJSON() throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    let textURL = TranscriptDocument.plainTextURL(for: directory)
    try FileManager.default.createDirectory(at: textURL, withIntermediateDirectories: false)
    let document = TranscriptDocument(
      segments: [.init(speaker: 1, time: 2, text: "Saved")], createdAt: Date())
    try document.save(for: directory)
    #expect(TranscriptDocument.load(for: directory)?.segments.map(\.text) == ["Saved"])
    #expect(!FileManager.default.fileExists(atPath: textURL.path))
  }

  @Test("a transcript written before a field existed still decodes")
  func transcriptDecodesWithMissingKeys() throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    let json = #"{"segments":[{"speaker":1,"time":0,"text":"hello"}]}"#
    try Data(json.utf8).write(to: TranscriptDocument.sidecarURL(for: directory))

    let loaded = try #require(TranscriptDocument.load(for: directory))
    #expect(loaded.segments.count == 1)
    #expect(loaded.segments.first?.text == "hello")
  }

  /// The cost of losing a transcript is a paid-for result vanishing and the user
  /// pressing Transcribe again, so one malformed segment must not take the other
  /// four hundred with it. `decodeIfPresent` only covers a *missing* key - a key
  /// present with the wrong type still throws, and that throw propagates out of
  /// the segment array and loses the whole document.
  @Test("one malformed segment does not lose the rest of the transcript")
  func transcriptSurvivesMalformedSegment() throws {
    let harness = try TranscriptionHarness()
    let shapes: [(String, String)] = [
      ("speaker as a string", #"{"speaker":"1","time":0,"text":"a"}"#),
      ("time as a string", #"{"speaker":1,"time":"0","text":"a"}"#),
      ("text as a number", #"{"speaker":1,"time":0,"text":7}"#),
      ("null values", #"{"speaker":null,"time":null,"text":null}"#),
      ("missing every key", #"{}"#),
    ]
    for (name, bad) in shapes {
      let directory = try harness.makeRecording("call-\(UUID().uuidString)")
      let json = #"{"segments":[\#(bad),{"speaker":2,"time":9,"text":"survivor"}]}"#
      try Data(json.utf8).write(to: TranscriptDocument.sidecarURL(for: directory))

      let loaded = try #require(TranscriptDocument.load(for: directory), "lost the file: \(name)")
      #expect(loaded.segments.count == 2, "lost a segment: \(name)")
      #expect(loaded.segments.last?.text == "survivor", "lost the good segment: \(name)")
    }
  }

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
    await harness.wait { TranscriptionJob.load(for: directory) == nil }
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

  /// `transcribe` reset the sidecar and dispatched remote DELETEs before
  /// `enqueue`'s in-flight guard could reject the request, so asking again for a
  /// running job destroyed that job's remote artifacts and erased its ids.
  @Test("asking again for a running job does not delete its remote artifacts")
  func repeatRequestLeavesRunningJobAlone() async throws {
    let harness = try TranscriptionHarness()
    await harness.service.setHoldsCompletion(true)
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.transcribe(recordingDirectory: directory)
    await harness.wait { coordinator.status(for: directory) == .transcribing }

    coordinator.transcribe(recordingDirectory: directory)

    #expect(await harness.service.deletedFileIds.isEmpty)
    #expect(await harness.service.deletedTranscriptionIds.isEmpty)
    let job = try #require(TranscriptionJob.load(for: directory))
    #expect(job.transcriptionId == "transcription-1")

    coordinator.cancel(recordingDirectory: directory)
  }

  /// `.cancelling` is `isActive`, so a progress report arriving after the user
  /// pressed Cancel overwrote it and re-enabled the button.
  @Test("a progress report does not undo a cancellation")
  func progressDoesNotOverwriteCancelling() async throws {
    let harness = try TranscriptionHarness()
    await harness.service.setHoldsUpload(true)
    await harness.service.setHoldIgnoresCancellation(true)
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.transcribe(recordingDirectory: directory)
    await harness.wait { coordinator.status(for: directory) == .uploading(fraction: 0.5) }

    coordinator.cancel(recordingDirectory: directory)
    #expect(coordinator.status(for: directory) == .cancelling)

    // A mix reports every 0.5s and runs for minutes on a long call, so a report
    // landing after the click is the normal case, not a rare one.
    await harness.service.emitProgress(.uploading(0.9))
    try await Task.sleep(for: .milliseconds(50))
    #expect(coordinator.status(for: directory) == .cancelling)

    await harness.service.setHoldIgnoresCancellation(false)
    await harness.service.setHoldsUpload(false)
  }

  // Quit can land after enqueue but before the job reaches the upload gate.
  @Test("suspend before the gate keeps the sidecar and uploads nothing")
  func suspendedBeforeGateKeepsSidecar() async throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    coordinator.transcribe(recordingDirectory: directory)
    coordinator.prepareForTermination()

    await harness.wait(upTo: 0.5) { await harness.service.uploadCount > 0 }
    #expect(await harness.service.uploadCount == 0)
    #expect(TranscriptionJob.load(for: directory) != nil, "sidecar was destroyed")
    #expect(coordinator.status(for: directory) == .queued)
  }

  // A job parked on the upload gate when quit arrives keeps its sidecar, so
  // the next launch resumes it instead of re-uploading.
  @Test("a waiter drained at quit keeps its sidecar")
  func drainedWaiterKeepsSidecar() async throws {
    let harness = try TranscriptionHarness()
    harness.uploadConcurrency = 1
    await harness.service.setHoldsUpload(true)
    let first = try harness.makeRecording("call-1")
    let second = try harness.makeRecording("call-2")
    let coordinator = harness.makeCoordinator()

    coordinator.transcribe(recordingDirectory: first)
    await harness.wait { await harness.service.uploadsInFlight == 1 }
    coordinator.transcribe(recordingDirectory: second)
    // Long enough that `second`'s task has certainly reached the gate. It is
    // parked there rather than inside `upload`, which `uploadCount == 1` proves
    // - so the only way it can be resumed is the drain in `releaseUploadSlot`.
    try await Task.sleep(for: .milliseconds(300))
    #expect(await harness.service.uploadCount == 1, "second was not parked on the gate")

    coordinator.prepareForTermination()
    await harness.service.setHoldsUpload(false)
    await harness.wait { coordinator.status(for: first) == .completed }
    // Give the drained waiter a chance to do the wrong thing.
    try await Task.sleep(for: .milliseconds(200))

    #expect(await harness.service.uploadCount == 1, "the drained waiter uploaded anyway")
    #expect(TranscriptionJob.load(for: second) != nil, "drained waiter lost its sidecar")
  }

  // Cancelling is the one case that does drop the sidecar.
  @Test("a cancelled waiter drops its sidecar")
  func cancelledWaiterDrops() async throws {
    let harness = try TranscriptionHarness()
    harness.uploadConcurrency = 1
    await harness.service.setHoldsUpload(true)
    let first = try harness.makeRecording("call-1")
    let second = try harness.makeRecording("call-2")
    let coordinator = harness.makeCoordinator()

    coordinator.transcribe(recordingDirectory: first)
    await harness.wait { await harness.service.uploadsInFlight == 1 }
    coordinator.transcribe(recordingDirectory: second)
    await harness.wait { coordinator.status(for: second) == .queued }

    coordinator.cancel(recordingDirectory: second)
    await harness.wait { TranscriptionJob.load(for: second) == nil }
    #expect(TranscriptionJob.load(for: second) == nil)

    await harness.service.setHoldsUpload(false)
    await harness.wait { coordinator.status(for: first) == .completed }
  }

  // The job is read before the trash moves the directory, so the remote
  // DELETE still goes out for a recording the user deleted.
  @Test("forgetDeletedRecording deletes remote artifacts from the passed job")
  func forgetDeletedDispatchesDelete() async throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call-1")
    let coordinator = harness.makeCoordinator()

    let job = TranscriptionJob(fileId: "file-9", transcriptionId: "transcription-9")
    job.save(for: directory)
    let captured = TranscriptionJob.load(for: directory)
    try FileManager.default.removeItem(at: directory)

    coordinator.forgetDeletedRecording(recordingDirectory: directory, job: captured)
    await harness.wait { await harness.service.deletedFileIds == ["file-9"] }
    #expect(await harness.service.deletedFileIds == ["file-9"])
    #expect(await harness.service.deletedTranscriptionIds == ["transcription-9"])
  }

  // A refused DELETE must not take the record with it: that record is the only
  // thing naming audio that is still sitting on Soniox.
  @Test("a cleanup the server refuses keeps its marker for the next launch")
  func refusedCleanupKeepsItsMarker() async throws {
    let harness = try TranscriptionHarness()
    await harness.service.setDeleteSucceeds(false)
    let directory = try harness.makeRecording("call-1")
    TranscriptionJob(
      fileId: "file-1", transcriptionId: "transcription-1", awaitingRemoteDelete: true
    ).save(for: directory)
    let coordinator = harness.makeCoordinator()

    coordinator.resumePendingJobs()
    await harness.wait { await harness.service.deletedFileIds == ["file-1"] }
    // Long enough for a retirement to have landed if one were coming.
    try await Task.sleep(for: .milliseconds(200))

    #expect(TranscriptionJob.load(for: directory)?.awaitingRemoteDelete == true)
    #expect(TranscriptionJob.load(for: directory)?.fileId == "file-1")
  }
}

@Suite("Local attribution lifecycle")
struct AttributionCoordinatorTests {
  private actor AnalysisGate {
    var calls = 0
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func analyze(audio: URL, tokens: [TranscriptToken]) async -> SpeakerAttribution {
      calls += 1
      if !isOpen { await withCheckedContinuation { waiting.append($0) } }
      return SpeakerAttribution(
        version: MicActivity.version, parameters: .init(),
        thresholds: TestFixtures.thresholds,
        localTokenIndices: Array(tokens.indices),
        appliedAt: Date())
    }

    func release() {
      isOpen = true
      for waiter in waiting { waiter.resume() }
      waiting.removeAll()
    }
  }

  private enum Interruption: CaseIterable {
    case quit, move, delete, replace, saveFailure, disable
  }

  @Test(arguments: Interruption.allCases)
  private func interruptedAttributionPreservesThePaidResult(action: Interruption) async throws {
    let harness = try TranscriptionHarness()
    harness.micEnabled = true
    let gate = AnalysisGate()
    harness.analyzeMic = { await gate.analyze(audio: $0, tokens: $1) }
    var saveAttempts = 0
    harness.saveProjectedTranscript = { _, _ in
      saveAttempts += 1
      throw CocoaError(.fileWriteNoPermission)
    }
    let coordinator = harness.makeCoordinator()
    let directory = try harness.makeRecording("call")
    coordinator.transcribe(recordingDirectory: directory)
    await harness.wait { await gate.calls == 1 }
    let paid = try #require(TranscriptDocument.load(for: directory))
    let sidecar = TranscriptDocument.sidecarURL(for: directory)
    let before = try Data(contentsOf: sidecar)
    let tokens = try #require(TranscriptTokens.load(for: directory))
    #expect(tokens.sourceAudio == RecordingStore.audioName)
    #expect(tokens.attribution == nil)
    #expect(harness.hookedDirectories.isEmpty)
    let json = try #require(JSONSerialization.jsonObject(with: before) as? [String: Any])
    #expect(Set(json.keys) == ["segments", "language", "createdAt"])
    let originalTokens = try Data(contentsOf: TranscriptTokens.url(for: directory))
    #expect(!originalTokens.contains(UInt8(ascii: "\n")))
    #expect(coordinator.status(for: directory) == .completed)
    await harness.wait { TranscriptionJob.load(for: directory) == nil }
    #expect(await harness.service.deletedFileIds == ["file-1"])

    let pending = try #require(coordinator.refreshAttribution(in: directory))
    switch action {
    case .quit:
      coordinator.prepareForTermination()
      #expect(harness.speakersAtHook == [[1]])
    case .move:
      coordinator.endPendingAttributions()
      #expect(harness.speakersAtHook == [[1]])
      try FileManager.default.moveItem(
        at: directory, to: harness.root.appendingPathComponent("moved"))
    case .delete:
      try FileManager.default.removeItem(at: directory)
      coordinator.forgetDeletedRecording(recordingDirectory: directory, job: nil)
    case .replace:
      let replacement = TranscriptDocument(
        tokens: [TranscriptToken(text: "new", startMs: 200, endMs: 400, speaker: 3)],
        createdAt: paid.createdAt)
      try replacement.save(for: directory)
    case .disable:
      harness.micEnabled = false
      coordinator.attributionSettingChanged()
    case .saveFailure: break
    }
    await gate.release()
    await pending.value
    #expect(harness.hookedDirectories == (action == .delete ? [] : [directory]))
    #expect(saveAttempts == (action == .saveFailure ? 1 : 0))
    if action == .delete || action == .move {
      #expect(!FileManager.default.fileExists(atPath: directory.path))
    } else if action == .replace {
      #expect(TranscriptDocument.load(for: directory)?.segments.first?.text == "new")
    } else {
      #expect(try Data(contentsOf: sidecar) == before)
      #expect(coordinator.status(for: directory) == .completed)
    }
    if action == .saveFailure {
      #expect(try Data(contentsOf: TranscriptTokens.url(for: directory)) == originalTokens)
    }
    #expect(TranscriptionJob.load(for: directory) == nil)
    #expect(coordinator.finishCount(for: directory) == 1)
  }

  @Test func deadlineFiresOnceWhileAnalysisFinishes() async throws {
    let harness = try TranscriptionHarness()
    harness.micEnabled = true
    let gate = AnalysisGate()
    harness.analyzeMic = { await gate.analyze(audio: $0, tokens: $1) }
    let clock = TestClock()
    var deadlineStarted = false
    harness.sleepForAttributionDeadline = { duration in
      #expect(duration == .seconds(120))
      deadlineStarted = true
      await clock.sleep(for: duration)
    }
    let directory = try harness.makeRecording("call")
    let coordinator = harness.makeCoordinator()
    coordinator.transcribe(recordingDirectory: directory)
    await harness.wait { await gate.calls == 1 && deadlineStarted }
    let analysis = try #require(coordinator.refreshAttribution(in: directory))
    clock.advance(by: .seconds(119))
    #expect(harness.hookedDirectories.isEmpty)
    clock.advance(by: .seconds(1))
    await harness.wait { harness.hookedDirectories == [directory] }
    #expect(harness.speakersAtHook == [[1]])
    #expect(!analysis.isCancelled)
    await gate.release()
    await analysis.value
    #expect(
      TranscriptDocument.load(for: directory)?.segments.first?.speaker
        == TranscriptSegment.localSpeaker)
    #expect(TranscriptTokens.load(for: directory)?.attribution?.localTokenIndices == [0])
    #expect(harness.hookedDirectories == [directory])
  }

  @Test func failedReplacementSaveLeavesPreviousPaidHookPending() async throws {
    let harness = try TranscriptionHarness()
    harness.micEnabled = true
    let gate = AnalysisGate()
    harness.analyzeMic = { await gate.analyze(audio: $0, tokens: $1) }
    let coordinator = harness.makeCoordinator()
    let directory = try harness.makeRecording("call")
    coordinator.transcribe(recordingDirectory: directory)
    await harness.wait { await gate.calls == 1 }
    let pending = try #require(coordinator.refreshAttribution(in: directory))
    let transcriptURL = TranscriptDocument.sidecarURL(for: directory)
    let original = directory.appendingPathComponent("original")
    try FileManager.default.moveItem(at: transcriptURL, to: original)
    try FileManager.default.createDirectory(at: transcriptURL, withIntermediateDirectories: false)
    coordinator.transcribe(recordingDirectory: directory)
    await harness.wait {
      if case .error = coordinator.status(for: directory) { true } else { false }
    }
    guard case .error = coordinator.status(for: directory) else {
      Issue.record("The replacement transcript write should fail")
      await gate.release()
      return
    }
    #expect(!pending.isCancelled)
    #expect(harness.hookedDirectories.isEmpty)
    try FileManager.default.removeItem(at: transcriptURL)
    try FileManager.default.moveItem(at: original, to: transcriptURL)
    await gate.release()
    await pending.value
    #expect(harness.speakersAtHook == [[TranscriptSegment.localSpeaker]])
  }

  @Test func concurrentPaidAttributionsReloadBothRecordings() async throws {
    let harness = try TranscriptionHarness()
    harness.micEnabled = true
    let gate = AnalysisGate()
    harness.analyzeMic = { await gate.analyze(audio: $0, tokens: $1) }
    let coordinator = harness.makeCoordinator()
    let directories = try ["a", "b"].map(harness.makeRecording)
    for directory in directories { coordinator.transcribe(recordingDirectory: directory) }
    await harness.wait { await gate.calls == 2 }
    let tasks = directories.compactMap { coordinator.refreshAttribution(in: $0) }
    for directory in directories { coordinator.cancelLazyAnalysis(in: directory) }
    await gate.release()
    for task in tasks { await task.value }
    for directory in directories {
      #expect(coordinator.finishCount(for: directory) == 2)
      #expect(
        TranscriptDocument.load(for: directory)?.segments.first?.speaker
          == TranscriptSegment.localSpeaker)
    }
    #expect(Set(harness.hookedDirectories) == Set(directories))
    #expect(
      harness.speakersAtHook == [
        [TranscriptSegment.localSpeaker], [TranscriptSegment.localSpeaker],
      ])
    #expect(harness.textAtHook.allSatisfy { $0.contains("You: hello") })
  }

  private func saveFixture(in directory: URL, local: Bool = false) throws {
    var document = TranscriptDocument(
      tokens: [TranscriptToken(text: "hello", startMs: 100, endMs: 200, speaker: 1)],
      createdAt: Date())
    var tokens = try #require(document.fetchedTokens)
    tokens.sourceAudio = RecordingStore.audioName
    if local {
      tokens.attribution = SpeakerAttribution(
        version: MicActivity.version, parameters: .init(),
        thresholds: TestFixtures.thresholds, localTokenIndices: [0], appliedAt: Date())
      document.segments = tokens.project()
    }
    try document.save(for: directory)
    try TranscriptTokens.write(JSONEncoder().encode(tokens), for: directory)
  }

  private func replaceAttribution(in directory: URL, with record: [String: Any]) throws {
    let url = TranscriptTokens.url(for: directory)
    var json = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    json["attribution"] = record
    try JSONSerialization.data(withJSONObject: json).write(to: url, options: .atomic)
  }

  @Test func pendingLaunchRestoreWorksOfflineAndClearsOnceComplete() async throws {
    let harness = try TranscriptionHarness()
    harness.apiKey = nil
    let coordinator = harness.makeCoordinator()
    #expect(coordinator.restoreProviderSpeakersIfPending() == nil)
    let directories = try ["attributed", "damaged"].map(harness.makeRecording)
    for directory in directories { try saveFixture(in: directory, local: true) }
    try replaceAttribution(in: directories[1], with: ["version": "bad"])
    harness.micEnabled = true
    coordinator.attributionSettingChanged()
    harness.micEnabled = false
    let interrupted = try #require(coordinator.restoreProviderSpeakersIfPending())
    coordinator.prepareForTermination()
    await interrupted.value
    let offline = harness.makeCoordinator()
    let sweep = try #require(offline.restoreProviderSpeakersIfPending())
    await sweep.value
    for directory in directories {
      #expect(offline.finishCount(for: directory) == 1)
      #expect(TranscriptDocument.load(for: directory)?.segments.first?.speaker == 1)
      #expect(
        try String(contentsOf: TranscriptDocument.plainTextURL(for: directory), encoding: .utf8)
          .contains("Speaker 2: hello"))
      #expect(TranscriptTokens.load(for: directory)?.hasAttributionRecord == false)
    }
    #expect(harness.makeCoordinator().restoreProviderSpeakersIfPending() == nil)
    #expect(harness.hookedDirectories.isEmpty)
    #expect(await harness.service.createCount == 0)
  }

  @Test func disablingRestoresEvenWithoutAPendingFlag() async throws {
    let harness = try TranscriptionHarness()
    harness.micEnabled = true
    let directory = try harness.makeRecording("attributed")
    try saveFixture(in: directory, local: true)
    let coordinator = harness.makeCoordinator()
    let flag = SettingsKeys.micAttributionRestorePending
    #expect(!harness.defaults.bool(forKey: flag))
    harness.micEnabled = false
    coordinator.attributionSettingChanged()
    #expect(harness.defaults.bool(forKey: flag))
    await harness.wait { !harness.defaults.bool(forKey: flag) }
    #expect(!harness.defaults.bool(forKey: flag))
    #expect(TranscriptDocument.load(for: directory)?.segments.first?.speaker == 1)
    #expect(harness.hookedDirectories.isEmpty)
  }

  @Test func failedRestoreKeepsTheSweepPendingForRetry() async throws {
    let harness = try TranscriptionHarness()
    let failing = try harness.makeRecording("failing")
    let healthy = try harness.makeRecording("healthy")
    for directory in [failing, healthy] { try saveFixture(in: directory, local: true) }
    var failWrite = true
    harness.saveProjectedTranscript = { encoded, directory in
      if failWrite, directory.path == failing.path { throw CocoaError(.fileWriteNoPermission) }
      try TranscriptDocument.save(encoded, for: directory)
    }
    let coordinator = harness.makeCoordinator()
    harness.defaults.set(true, forKey: SettingsKeys.micAttributionRestorePending)
    await coordinator.restoreProviderSpeakersIfPending()?.value
    #expect(TranscriptDocument.load(for: healthy)?.segments.first?.speaker == 1)
    #expect(
      TranscriptDocument.load(for: failing)?.segments.first?.speaker
        == TranscriptSegment.localSpeaker)
    failWrite = false
    let retry = try #require(coordinator.restoreProviderSpeakersIfPending())
    await retry.value
    #expect(TranscriptDocument.load(for: failing)?.segments.first?.speaker == 1)
    #expect(coordinator.restoreProviderSpeakersIfPending() == nil)
    #expect(harness.hookedDirectories.isEmpty)
  }

  private enum OlderRecord: CaseIterable {
    case missingProvenance, tokenBasedVersionTwo, absentParameters, invalidVersion, invalidIndices
  }

  @Test(arguments: OlderRecord.allCases)
  private func openingRepairsOldAttributionOffline(record: OlderRecord) async throws {
    let harness = try TranscriptionHarness()
    harness.micEnabled = true
    harness.apiKey = nil
    let gate = AnalysisGate()
    harness.analyzeMic = { await gate.analyze(audio: $0, tokens: $1) }
    let coordinator = harness.makeCoordinator()
    let directory = try harness.makeRecording("opened")
    let unopened = try harness.makeRecording("unopened")
    try saveFixture(in: directory)
    try saveFixture(in: unopened)
    var old: [String: Any] = [
      "version": 1, "localTokenIndices": [],
      "parameters": ["sampleRate": 8000], "thresholds": ["micThresholdDBFS": -48],
    ]
    switch record {
    case .missingProvenance: break
    case .tokenBasedVersionTwo: old["version"] = 2
    case .absentParameters:
      old["version"] = 2
      old.removeValue(forKey: "parameters")
    case .invalidVersion: old["version"] = "bad"
    case .invalidIndices: old["localTokenIndices"] = "bad"
    }
    try replaceAttribution(in: directory, with: old)
    let decoded = TranscriptTokens.load(for: directory)?.attribution
    if record == .missingProvenance || record == .tokenBasedVersionTwo {
      #expect(decoded?.parameters.sampleRate == 8000)
      #expect(
        decoded?.parameters.minimumLocalFraction == MicActivity.Parameters().minimumLocalFraction)
      #expect(decoded?.thresholds.micThresholdDBFS == -48)
      #expect(decoded?.thresholds.usedAdaptiveMicThreshold == false)
    } else if record == .absentParameters {
      #expect(decoded?.isCurrent == false)
    } else {
      #expect(decoded == nil)
    }
    let pending = try #require(coordinator.refreshAttribution(in: directory))
    await gate.release()
    await pending.value
    #expect(TranscriptTokens.load(for: directory)?.attribution?.version == MicActivity.version)
    #expect(
      TranscriptDocument.load(for: directory)?.segments.first?.speaker
        == TranscriptSegment.localSpeaker)
    #expect(TranscriptDocument.load(for: unopened)?.segments.first?.speaker == 1)
    let relaunched = harness.makeCoordinator()
    await relaunched.refreshAttribution(in: directory)?.value
    #expect(relaunched.refreshAttribution(in: directory) == nil)
    #expect(await gate.calls == 1)
    #expect(harness.hookedDirectories.isEmpty)
    #expect(await harness.service.createCount == 0)
  }

  @Test func closingDetailCancelsLazyAnalysisAndReopeningCanRetry() async throws {
    let harness = try TranscriptionHarness()
    harness.micEnabled = true
    let directory = try harness.makeRecording("opened")
    try saveFixture(in: directory)
    let gate = AnalysisGate()
    harness.analyzeMic = { await gate.analyze(audio: $0, tokens: $1) }
    let coordinator = harness.makeCoordinator()
    let first = try #require(coordinator.refreshAttribution(in: directory))
    await harness.wait { await gate.calls == 1 }
    coordinator.cancelLazyAnalysis(in: directory)
    #expect(first.isCancelled)
    await gate.release()
    await first.value
    #expect(coordinator.finishCount(for: directory) == 0)
    #expect(TranscriptTokens.load(for: directory)?.attribution == nil)
    await coordinator.refreshAttribution(in: directory)?.value
    #expect(coordinator.finishCount(for: directory) == 1)
    #expect(await gate.calls == 2)
    #expect(harness.hookedDirectories.isEmpty)
  }

  @Test func togglingDuringAnalysisKeepsOnlyTheLatestProjection() async throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call")
    let gate = AnalysisGate()
    harness.micEnabled = true
    harness.analyzeMic = { await gate.analyze(audio: $0, tokens: $1) }
    let coordinator = harness.makeCoordinator()
    coordinator.transcribe(recordingDirectory: directory)
    await harness.wait { await gate.calls == 1 }
    let first = try #require(coordinator.refreshAttribution(in: directory))
    harness.micEnabled = false
    coordinator.attributionSettingChanged()
    #expect(harness.speakersAtHook == [[1]])
    harness.micEnabled = true
    coordinator.attributionSettingChanged()
    let latest = try #require(coordinator.refreshAttribution(in: directory))
    await harness.wait { await gate.calls == 2 }
    let metadata = RecordingMetadata(
      title: "call", createdAt: Date(), appName: "Meet",
      speakers: [String(TranscriptSegment.localSpeaker): "Local"])
    try metadata.save(in: directory)
    await gate.release()
    await first.value
    await latest.value
    let document = try #require(TranscriptDocument.load(for: directory))
    #expect(document.segments.map(\.speaker) == [TranscriptSegment.localSpeaker])
    #expect(document.segments.map { $0.exported(using: metadata).speaker } == ["Local"])
    #expect(
      try String(contentsOf: TranscriptDocument.plainTextURL(for: directory), encoding: .utf8)
        .contains("Local: hello"))
    #expect(coordinator.finishCount(for: directory) == 2)
    #expect(harness.hookedDirectories == [directory])
  }

  @Test func unwritableTokensStillDeliverThePaidTranscript() async throws {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call")
    let tokensURL = TranscriptTokens.url(for: directory)
    try FileManager.default.createDirectory(at: tokensURL, withIntermediateDirectories: false)
    let sentinel = tokensURL.appendingPathComponent("keep")
    try Data([1]).write(to: sentinel)
    harness.micEnabled = true
    let coordinator = harness.makeCoordinator()
    coordinator.transcribe(recordingDirectory: directory)
    await harness.wait { coordinator.status(for: directory) == .completed }
    #expect(harness.speakersAtHook == [[1]])
    #expect(try Data(contentsOf: sentinel) == Data([1]))
    await coordinator.refreshAttribution(in: directory)?.value
    #expect(harness.hookedDirectories == [directory])
  }

  private enum NegativeAnalysis: CaseIterable { case failure, noFrames, noMatches }

  @Test(arguments: NegativeAnalysis.allCases)
  private func negativeAnalysisIsRememberedUntilAnotherPaidSave(outcome: NegativeAnalysis)
    async throws
  {
    let harness = try TranscriptionHarness()
    let directory = try harness.makeRecording("call")
    let gate = AnalysisGate()
    harness.micEnabled = true
    harness.analyzeMic = { audio, tokens in
      let result = await gate.analyze(audio: audio, tokens: tokens)
      switch outcome {
      case .failure: throw CocoaError(.fileReadCorruptFile)
      case .noFrames: return nil
      case .noMatches:
        return SpeakerAttribution(
          version: result.version, parameters: result.parameters, thresholds: result.thresholds,
          localTokenIndices: [], appliedAt: result.appliedAt)
      }
    }
    let coordinator = harness.makeCoordinator()
    coordinator.transcribe(recordingDirectory: directory)
    await harness.wait { await gate.calls == 1 }
    #expect(harness.hookedDirectories.isEmpty)
    let transcriptURL = TranscriptDocument.sidecarURL(for: directory)
    let inode =
      try FileManager.default.attributesOfItem(atPath: transcriptURL.path)[.systemFileNumber]
      as? NSNumber
    await gate.release()
    await harness.wait { harness.speakersAtHook == [[1]] }
    #expect(coordinator.refreshAttribution(in: directory) == nil)
    #expect(await gate.calls == 1)
    #expect(coordinator.finishCount(for: directory) == 1)
    if outcome == .noMatches {
      let attribution = try #require(TranscriptTokens.load(for: directory)?.attribution)
      #expect(attribution.version == MicActivity.version && attribution.localTokenIndices.isEmpty)
      let relaunched = harness.makeCoordinator()
      await relaunched.refreshAttribution(in: directory)?.value
      #expect(relaunched.refreshAttribution(in: directory) == nil)
      #expect(await gate.calls == 1)
      harness.micEnabled = false
      await relaunched.restoreProviderSpeakersIfPending()?.value
      #expect(TranscriptTokens.load(for: directory)?.hasAttributionRecord == false)
      #expect(relaunched.finishCount(for: directory) == 0)
      #expect(
        try FileManager.default.attributesOfItem(atPath: transcriptURL.path)[.systemFileNumber]
          as? NSNumber == inode)
      harness.micEnabled = true
    }
    coordinator.transcribe(recordingDirectory: directory)
    await harness.wait { harness.hookedDirectories.count == 2 }
    #expect(await gate.calls == 2)
    #expect(harness.speakersAtHook == [[1], [1]])
  }

  private enum Skip: CaseIterable {
    case off, processed, resumedProcessed, unknownSource, suspended
  }

  @Test(arguments: Skip.allCases)
  private func skipsAnalysis(reason: Skip) async throws {
    let harness = try TranscriptionHarness()
    harness.micEnabled = reason != .off
    let coordinator = harness.makeCoordinator()
    let directory = try harness.makeRecording("call")
    if reason == .processed {
      try Data([1]).write(to: directory.appendingPathComponent(RecordingStore.processedAudioName))
    }
    let isResumed = reason == .resumedProcessed || reason == .unknownSource
    if isResumed {
      TranscriptionJob(
        fileId: "file", transcriptionId: "id",
        sourceAudio: reason == .resumedProcessed ? RecordingStore.processedAudioName : nil
      ).save(for: directory)
      coordinator.resumePendingJobs()
    } else {
      if reason == .suspended { harness.micEnabled = false }
      coordinator.transcribe(recordingDirectory: directory)
    }
    await harness.wait { coordinator.status(for: directory) == .completed }
    #expect(harness.hookedDirectories.map(\.path) == [directory.path])
    if reason == .suspended {
      harness.micEnabled = true
      coordinator.prepareForTermination()
      #expect(coordinator.refreshAttribution(in: directory) == nil)
    } else {
      let task = coordinator.refreshAttribution(in: directory)
      await task?.value
    }
    let doc = try #require(TranscriptDocument.load(for: directory))
    #expect(TranscriptTokens.load(for: directory)?.attribution == nil)
    #expect(doc.segments.first?.speaker == 1)
    if reason == .processed || reason == .resumedProcessed {
      #expect(
        TranscriptTokens.load(for: directory)?.sourceAudio == RecordingStore.processedAudioName)
    }
    if isResumed { #expect(await harness.service.uploadCount == 0) }
    if reason == .unknownSource {
      #expect(TranscriptTokens.load(for: directory)?.sourceAudio == nil)
    }
  }
}
