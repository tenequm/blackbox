import Foundation

// MARK: - Persisted Job

/// On-disk record of an in-flight transcription, written beside the recording.
/// A job interrupted by quit or a crash resumes from its persisted stage on the
/// next launch instead of re-uploading audio that Soniox already holds.
nonisolated struct TranscriptionJob: Codable, Sendable {
  var fileId: String?
  var transcriptionId: String?
  var attempts: Int = 0
  /// Whether the job came from the auto-transcribe setting rather than an
  /// explicit user action. Resume re-checks the setting for these.
  var isAutomatic: Bool = false
  /// Set only on terminal failure. Its presence is what stops a launch resume
  /// from silently spending another upload on a job that already failed.
  var lastError: String?

  static let fileName = "transcription-job.json"

  static func url(for recordingDirectory: URL) -> URL {
    recordingDirectory.appendingPathComponent(fileName)
  }

  static func load(for recordingDirectory: URL) -> TranscriptionJob? {
    guard let data = try? Data(contentsOf: url(for: recordingDirectory)) else { return nil }
    return try? JSONDecoder().decode(TranscriptionJob.self, from: data)
  }

  static func remove(for recordingDirectory: URL) {
    try? FileManager.default.removeItem(at: url(for: recordingDirectory))
  }

  func save(for recordingDirectory: URL) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(self) else { return }
    try? data.write(to: Self.url(for: recordingDirectory), options: .atomic)
  }
}

// MARK: - Coordinator

/// App-level owner of transcription work. Lives for the process, not for a
/// window, so a job started from the detail view survives that window closing
/// and an auto-triggered job has somewhere to live at all.
///
/// One job runs at a time. Everything is best-effort: a failure here never
/// touches the recording, and nothing on this path is allowed to extend
/// `applicationShouldTerminate`'s budget - an interrupted job resumes on the
/// next launch from its sidecar.
@Observable
final class TranscriptionCoordinator {
  struct Dependencies {
    var makeService: (String) -> any TranscriptionServicing = { key in
      TranscriptionService(
        apiKey: key,
        model: TranscriptionService.resolvedModel(
          UserDefaults.standard.string(forKey: "sonioxModel")))
    }
    var apiKey: () -> String? = {
      let key = KeychainHelper.string(forKey: "sonioxAPIKey") ?? ""
      return key.isEmpty ? nil : key
    }
    var isAutoEnabled: () -> Bool = { UserDefaults.standard.bool(forKey: "autoTranscribe") }
    var saveDirectory: () -> URL = {
      URL(
        fileURLWithPath: UserDefaults.standard.string(forKey: "saveDirectoryPath")
          ?? defaultSaveDirectoryPath)
    }
    var sleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
  }

  /// What to do about a failure that interrupted a job.
  private enum FailurePolicy {
    case cancelled
    /// Not the job's fault and not worth an attempt - wait it out.
    case wait(Duration)
    case retry(Duration)
    case terminal(String)
  }

  /// Bumped whenever a job reaches a terminal state, so views can reload the
  /// sidecar files on disk without polling.
  private(set) var revision = 0

  private var statuses: [String: TranscriptionStatus] = [:]
  private var queue: [URL] = []
  private var activeDirectory: URL?
  private var runTask: Task<Void, Never>?
  private var gateTask: Task<Void, Never>?

  /// Transcription mixes and re-encodes the whole recording, so it is held back
  /// while the recorder owns the machine. Late-bound: the monitor and the
  /// coordinator are built together in `BlackboxApp` and neither can capture
  /// the other at init.
  @ObservationIgnored var isRecordingActive: () -> Bool = { false }

  @ObservationIgnored private let dependencies: Dependencies
  /// Outer nil means "not read yet". Cached because `hasAPIKey` is read from a
  /// SwiftUI body that re-evaluates at playback tick rate, and reading the key
  /// is a synchronous Keychain round-trip.
  @ObservationIgnored private var cachedAPIKey: String??

  private static let maxAttempts = 3
  /// Backstop against an error that classifies as retryable forever.
  private static let maxAttemptedPasses = 30
  /// Offline waits do not spend an attempt, so they get their own bound.
  private static let maxOfflineWaits = 60
  private static let offlineRetry = Duration.seconds(60)
  private static let recordingGate = Duration.seconds(30)

  init(dependencies: Dependencies = Dependencies()) {
    self.dependencies = dependencies
  }

  // MARK: - Queries

  func status(for recordingDirectory: URL) -> TranscriptionStatus {
    statuses[recordingDirectory.path] ?? .idle
  }

  var hasAPIKey: Bool { apiKey() != nil }

  private func apiKey() -> String? {
    if let cachedAPIKey { return cachedAPIKey }
    let key = dependencies.apiKey()
    cachedAPIKey = key
    return key
  }

  /// Settings writes the key straight to the Keychain, so the cache needs an
  /// explicit poke when it changes.
  func apiKeyChanged() {
    cachedAPIKey = nil
  }

  // MARK: - Triggers

  /// Auto-trigger for a finished recording. `audioFileURL` is what
  /// `AudioRecorder.stop()` hands back; the job is keyed by its directory.
  func recordingFinished(audioFileURL: URL) {
    guard dependencies.isAutoEnabled() else { return }
    guard apiKey() != nil else {
      Log.info(
        Log.transcription, "transcription",
        "auto-transcribe is on but no API key is configured; skipping")
      return
    }
    enqueue(audioFileURL.deletingLastPathComponent(), isAutomatic: true)
  }

  /// Manual trigger from the recording detail view, including retry after a failure.
  func transcribe(recordingDirectory: URL) {
    guard apiKey() != nil else { return }
    if var job = TranscriptionJob.load(for: recordingDirectory), job.lastError != nil {
      job.lastError = nil
      job.attempts = 0
      job.save(for: recordingDirectory)
    }
    enqueue(recordingDirectory, isAutomatic: false)
  }

  func cancel(recordingDirectory: URL) {
    queue.removeAll { $0.path == recordingDirectory.path }
    if activeDirectory?.path == recordingDirectory.path {
      runTask?.cancel()
      return
    }
    if let job = TranscriptionJob.load(for: recordingDirectory) {
      discardRemote(job: job)
    }
    TranscriptionJob.remove(for: recordingDirectory)
    statuses[recordingDirectory.path] = .idle
  }

  /// Re-enqueues jobs left behind by a quit or a crash. Two things are
  /// deliberately not resumed: a job that already failed terminally (spending
  /// another upload is the user's call), and an automatic job that has not
  /// uploaded anything yet if auto-transcribe has since been switched off. A
  /// job that *has* uploaded is finished either way - the audio is already on
  /// Soniox, and completing it beats stranding it there.
  func resumePendingJobs() {
    guard apiKey() != nil else { return }
    let directory = dependencies.saveDirectory()
    Task { [weak self] in
      await TranscriptionService.sweepTemporaryFiles()
      let pending = await Self.findPendingJobs(in: directory)
      guard let self else { return }
      for (recordingDirectory, job) in pending {
        let name = recordingDirectory.lastPathComponent
        if let lastError = job.lastError {
          self.statuses[recordingDirectory.path] = .error(lastError)
          continue
        }
        if job.isAutomatic, job.fileId == nil, !self.dependencies.isAutoEnabled() {
          Log.info(
            Log.transcription, "transcription",
            "dropping pending auto-transcription for \(name): the setting is now off")
          TranscriptionJob.remove(for: recordingDirectory)
          continue
        }
        Log.info(
          Log.transcription, "transcription", "resuming interrupted transcription for \(name)")
        self.enqueue(recordingDirectory, isAutomatic: job.isAutomatic)
      }
    }
  }

  // MARK: - Queue

  private func enqueue(_ recordingDirectory: URL, isAutomatic: Bool) {
    let key = recordingDirectory.path
    guard activeDirectory?.path != key, !queue.contains(where: { $0.path == key }) else { return }
    if TranscriptionJob.load(for: recordingDirectory) == nil {
      TranscriptionJob(isAutomatic: isAutomatic).save(for: recordingDirectory)
    }
    statuses[key] = .queued
    queue.append(recordingDirectory)
    pump()
  }

  private func pump() {
    guard activeDirectory == nil, let next = queue.first else { return }

    if isRecordingActive() {
      guard gateTask == nil else { return }
      let sleep = dependencies.sleep
      gateTask = Task { [weak self] in
        await sleep(Self.recordingGate)
        guard let self else { return }
        self.gateTask = nil
        self.pump()
      }
      return
    }

    queue.removeFirst()
    activeDirectory = next
    runTask = Task { [weak self] in
      await self?.run(next)
      guard let self else { return }
      self.activeDirectory = nil
      self.runTask = nil
      self.pump()
    }
  }

  // MARK: - Job Runner

  private func run(_ recordingDirectory: URL) async {
    let key = recordingDirectory.path
    let name = recordingDirectory.lastPathComponent

    guard let apiKey = apiKey() else {
      finish(key: key, status: .error("No Soniox API key configured"))
      return
    }
    guard let audioURL = RecordingStore.audioURL(in: recordingDirectory) else {
      Log.error(Log.transcription, "transcription", "no audio file in \(name), dropping job")
      TranscriptionJob.remove(for: recordingDirectory)
      statuses[key] = .idle
      return
    }

    let service = dependencies.makeService(apiKey)
    var job = TranscriptionJob.load(for: recordingDirectory) ?? TranscriptionJob()
    var attemptedPasses = 0
    var offlineWaits = 0

    while attemptedPasses < Self.maxAttemptedPasses, offlineWaits < Self.maxOfflineWaits {
      do {
        try Task.checkCancellation()

        if job.fileId == nil {
          statuses[key] = .uploading
          job.fileId = try await service.upload(fileURL: audioURL)
          job.save(for: recordingDirectory)
        }
        if job.transcriptionId == nil, let fileId = job.fileId {
          statuses[key] = .queued
          job.transcriptionId = try await service.createTranscription(
            fileId: fileId, reference: name)
          job.save(for: recordingDirectory)
        }
        guard let transcriptionId = job.transcriptionId else { break }

        statuses[key] = .transcribing
        try await service.awaitCompletion(transcriptionId: transcriptionId)
        let document = try await service.fetchTranscript(transcriptionId: transcriptionId)

        // The recording can be deleted while its job runs; writing the
        // transcript now would resurrect a file next to something that is
        // already in the Trash.
        guard FileManager.default.fileExists(atPath: key) else {
          Log.info(
            Log.transcription, "transcription",
            "\(name) went away mid-job, discarding transcript")
          discardRemote(job: job)
          statuses[key] = .idle
          return
        }

        do {
          try document.save(for: recordingDirectory)
        } catch {
          // The transcript is paid for and in hand; losing it to a write error
          // is worth an explicit failure rather than a silent retry.
          fail(&job, in: recordingDirectory, message: error.localizedDescription)
          Log.error(
            Log.transcription, "transcription",
            "failed to save transcript for \(name): \(error.localizedDescription)")
          return
        }

        TranscriptionJob.remove(for: recordingDirectory)
        finish(key: key, status: .completed)
        Log.info(Log.transcription, "transcription", "transcribed \(name)")
        await service.deleteRemote(
          transcriptionIds: [transcriptionId], fileIds: [job.fileId].compactMap { $0 })
        return
      } catch {
        switch failurePolicy(for: error, attempts: job.attempts) {
        case .cancelled:
          discardRemote(job: job)
          TranscriptionJob.remove(for: recordingDirectory)
          statuses[key] = .idle
          Log.info(Log.transcription, "transcription", "cancelled \(name)")
          return

        case .wait(let duration):
          offlineWaits += 1
          statuses[key] = .queued
          await dependencies.sleep(duration)

        case .retry(let duration):
          attemptedPasses += 1
          job.attempts += 1
          job.save(for: recordingDirectory)
          Log.error(
            Log.transcription, "transcription",
            "transient failure for \(name) (attempt \(job.attempts)/\(Self.maxAttempts)): \(error.localizedDescription)"
          )
          await dependencies.sleep(duration)

        case .terminal(let message):
          fail(&job, in: recordingDirectory, message: message)
          Log.error(Log.transcription, "transcription", "failed for \(name): \(message)")
          return
        }
      }
    }

    // Out of passes. The sidecar stays resumable rather than terminal: the last
    // thing seen was retryable, so the next launch should get another go.
    statuses[key] = .idle
    Log.error(
      Log.transcription, "transcription",
      "gave up on \(name) for now; it will be retried on next launch")
  }

  private func failurePolicy(for error: Error, attempts: Int) -> FailurePolicy {
    if Task.isCancelled || error is CancellationError { return .cancelled }
    // Offline is a wait, not a failure - it must not burn an attempt.
    if Self.isOffline(error) { return .wait(Self.offlineRetry) }
    if Self.isTransient(error), attempts < Self.maxAttempts {
      return .retry(Self.backoff(forAttempt: attempts + 1))
    }
    return .terminal(error.localizedDescription)
  }

  private func finish(key: String, status: TranscriptionStatus) {
    statuses[key] = status
    revision += 1
  }

  /// Terminal outcome: surface it and keep the sidecar so the detail view can
  /// offer a retry, but drop what the job already put on Soniox. A failed job
  /// the user never retries would otherwise leave the call audio there for good.
  private func fail(_ job: inout TranscriptionJob, in recordingDirectory: URL, message: String) {
    discardRemote(job: job)
    job.fileId = nil
    job.transcriptionId = nil
    job.lastError = message
    job.save(for: recordingDirectory)
    finish(key: recordingDirectory.path, status: .error(message))
  }

  /// Deletes whatever a job put on Soniox. Detached from the caller so it still
  /// runs when the job's own task was the thing that got cancelled.
  private func discardRemote(job: TranscriptionJob) {
    let transcriptionIds = [job.transcriptionId].compactMap { $0 }
    let fileIds = [job.fileId].compactMap { $0 }
    guard !transcriptionIds.isEmpty || !fileIds.isEmpty, let apiKey = apiKey() else { return }
    let service = dependencies.makeService(apiKey)
    Task {
      await service.deleteRemote(transcriptionIds: transcriptionIds, fileIds: fileIds)
    }
  }

  // MARK: - Helpers

  @concurrent
  nonisolated private static func findPendingJobs(in directory: URL) async
    -> [(URL, TranscriptionJob)]
  {
    RecordingStore.directories(in: directory).compactMap { entry in
      guard let job = TranscriptionJob.load(for: entry) else { return nil }
      return (entry, job)
    }
  }

  nonisolated private static func isOffline(_ error: Error) -> Bool {
    guard let error = error as? URLError else { return false }
    return error.code == .notConnectedToInternet || error.code == .dataNotAllowed
  }

  nonisolated private static func isTransient(_ error: Error) -> Bool {
    if let error = error as? URLError {
      return [
        URLError.Code.networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost,
        .dnsLookupFailed, .resourceUnavailable,
      ].contains(error.code)
    }
    if let error = error as? TranscriptionError {
      switch error {
      // `.notReady` is a 409 from fetching a transcript the server has not
      // finished publishing - the next pass re-polls and picks it up.
      case .serverError, .pollTimeout, .notReady: return true
      case .uploadFailed, .transcriptionFailed, .balanceExhausted: return false
      }
    }
    return false
  }

  /// 30s, 2m, 8m.
  nonisolated private static func backoff(forAttempt attempt: Int) -> Duration {
    .seconds(30 << (2 * max(0, attempt - 1)))
  }
}
