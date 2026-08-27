import Foundation

// MARK: - Persisted Job

/// On-disk record of an in-flight transcription, written beside the recording.
/// A job interrupted by quit or a crash resumes from its persisted stage on the
/// next launch instead of re-uploading audio that Soniox already holds.
nonisolated struct TranscriptionJob: Codable, Sendable {
  var fileId: String?
  var transcriptionId: String?
  var attempts: Int = 0
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
    var makeService: (String) -> any TranscriptionServicing = { TranscriptionService(apiKey: $0) }
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

  private static let maxAttempts = 3
  /// Backstop against an error that classifies as retryable forever.
  private static let maxIterations = 30
  private static let offlineRetry = Duration.seconds(60)
  private static let recordingGate = Duration.seconds(30)

  init(dependencies: Dependencies = Dependencies()) {
    self.dependencies = dependencies
  }

  // MARK: - Queries

  func status(for recordingDirectory: URL) -> TranscriptionStatus {
    statuses[recordingDirectory.path] ?? .idle
  }

  var hasAPIKey: Bool { dependencies.apiKey() != nil }

  // MARK: - Triggers

  /// Auto-trigger for a finished recording. `audioFileURL` is what
  /// `AudioRecorder.stop()` hands back; the job is keyed by its directory.
  func recordingFinished(audioFileURL: URL) {
    guard dependencies.isAutoEnabled() else { return }
    guard dependencies.apiKey() != nil else {
      Log.info(
        Log.transcription, "transcription",
        "auto-transcribe is on but no API key is configured; skipping")
      return
    }
    enqueue(audioFileURL.deletingLastPathComponent())
  }

  /// Manual trigger from the recording detail view, including retry after a failure.
  func transcribe(recordingDirectory: URL) {
    guard dependencies.apiKey() != nil else { return }
    if var job = TranscriptionJob.load(for: recordingDirectory), job.lastError != nil {
      job.lastError = nil
      job.attempts = 0
      job.save(for: recordingDirectory)
    }
    enqueue(recordingDirectory)
  }

  func cancel(recordingDirectory: URL) {
    queue.removeAll { $0.path == recordingDirectory.path }
    if activeDirectory?.path == recordingDirectory.path {
      runTask?.cancel()
      return
    }
    TranscriptionJob.remove(for: recordingDirectory)
    statuses[recordingDirectory.path] = .idle
  }

  /// Re-enqueues jobs left behind by a quit or a crash. A job that already
  /// failed terminally is surfaced rather than retried - spending another
  /// upload is the user's call, not ours.
  func resumePendingJobs() {
    guard dependencies.apiKey() != nil else { return }
    let directory = dependencies.saveDirectory()
    Task { [weak self] in
      let pending = await Self.findPendingJobs(in: directory)
      guard let self else { return }
      for (recordingDirectory, lastError) in pending {
        if let lastError {
          self.statuses[recordingDirectory.path] = .error(lastError)
        } else {
          Log.info(
            Log.transcription, "transcription",
            "resuming interrupted transcription for \(recordingDirectory.lastPathComponent)")
          self.enqueue(recordingDirectory)
        }
      }
    }
  }

  // MARK: - Queue

  private func enqueue(_ recordingDirectory: URL) {
    let key = recordingDirectory.path
    guard activeDirectory?.path != key, !queue.contains(where: { $0.path == key }) else { return }
    if TranscriptionJob.load(for: recordingDirectory) == nil {
      TranscriptionJob().save(for: recordingDirectory)
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

    guard let apiKey = dependencies.apiKey() else {
      statuses[key] = .error("No Soniox API key configured")
      return
    }
    guard let audioURL = Self.audioURL(in: recordingDirectory) else {
      Log.error(Log.transcription, "transcription", "no audio file in \(name), dropping job")
      TranscriptionJob.remove(for: recordingDirectory)
      statuses[key] = .idle
      return
    }

    let service = dependencies.makeService(apiKey)
    var job = TranscriptionJob.load(for: recordingDirectory) ?? TranscriptionJob()

    for _ in 0..<Self.maxIterations {
      do {
        if job.fileId == nil {
          statuses[key] = .uploading
          job.fileId = try await service.upload(fileURL: audioURL)
          job.save(for: recordingDirectory)
        }
        guard let fileId = job.fileId else { break }

        if job.transcriptionId == nil {
          statuses[key] = .queued
          job.transcriptionId = try await service.createTranscription(fileId: fileId)
          job.save(for: recordingDirectory)
        }
        guard let transcriptionId = job.transcriptionId else { break }

        statuses[key] = .queued
        try await service.awaitCompletion(transcriptionId: transcriptionId) { [weak self] status in
          Task { @MainActor in self?.statuses[key] = status }
        }
        let document = try await service.fetchTranscript(transcriptionId: transcriptionId)

        do {
          try document.save(for: recordingDirectory)
        } catch {
          // The transcript is paid for and in hand; losing it to a write error
          // is worth an explicit failure rather than a silent retry.
          finish(key: key, status: .error(error.localizedDescription))
          job.lastError = error.localizedDescription
          job.save(for: recordingDirectory)
          Log.error(
            Log.transcription, "transcription",
            "failed to save transcript for \(name): \(error.localizedDescription)")
          return
        }

        TranscriptionJob.remove(for: recordingDirectory)
        finish(key: key, status: .completed)
        Log.info(Log.transcription, "transcription", "transcribed \(name)")
        await service.deleteRemote(transcriptionIds: [transcriptionId], fileIds: [fileId])
        return
      } catch {
        if Task.isCancelled || error is CancellationError {
          cancelRemote(job: job, service: service)
          TranscriptionJob.remove(for: recordingDirectory)
          statuses[key] = .idle
          Log.info(Log.transcription, "transcription", "cancelled \(name)")
          return
        }

        // Offline is a wait, not a failure - it must not burn an attempt.
        if Self.isOffline(error) {
          statuses[key] = .queued
          await dependencies.sleep(Self.offlineRetry)
          continue
        }

        if Self.isTransient(error), job.attempts < Self.maxAttempts {
          job.attempts += 1
          job.save(for: recordingDirectory)
          Log.error(
            Log.transcription, "transcription",
            "transient failure for \(name) (attempt \(job.attempts)/\(Self.maxAttempts)): \(error.localizedDescription)"
          )
          await dependencies.sleep(Self.backoff(forAttempt: job.attempts))
          continue
        }

        job.lastError = error.localizedDescription
        job.save(for: recordingDirectory)
        finish(key: key, status: .error(error.localizedDescription))
        Log.error(
          Log.transcription, "transcription",
          "failed for \(name): \(error.localizedDescription)")
        return
      }
    }

    let message = "Transcription gave up after repeated failures"
    job.lastError = message
    job.save(for: recordingDirectory)
    finish(key: key, status: .error(message))
    Log.error(Log.transcription, "transcription", "\(message) for \(name)")
  }

  private func finish(key: String, status: TranscriptionStatus) {
    statuses[key] = status
    revision += 1
  }

  /// Drops the remote artifacts a cancelled job left behind. Detached from the
  /// cancelled task so the DELETEs actually run.
  private func cancelRemote(job: TranscriptionJob, service: any TranscriptionServicing) {
    let transcriptionIds = [job.transcriptionId].compactMap { $0 }
    let fileIds = [job.fileId].compactMap { $0 }
    guard !transcriptionIds.isEmpty || !fileIds.isEmpty else { return }
    Task {
      await service.deleteRemote(transcriptionIds: transcriptionIds, fileIds: fileIds)
    }
  }

  // MARK: - Helpers

  /// Echo-cancelled output when the user has run AEC, otherwise the raw capture.
  /// Resolved at run time so a resumed job picks up whatever exists now, and so
  /// this matches what the detail view plays back.
  nonisolated private static func audioURL(in recordingDirectory: URL) -> URL? {
    let processed = recordingDirectory.appendingPathComponent("audio-processed.m4a")
    if FileManager.default.fileExists(atPath: processed.path) { return processed }
    let raw = recordingDirectory.appendingPathComponent("audio.m4a")
    return FileManager.default.fileExists(atPath: raw.path) ? raw : nil
  }

  /// Scans by name rather than `contentsOfDirectory(at:)`, which resolves
  /// symlinks in the base and would hand back a different spelling of the same
  /// path than the recorder produces. Job status is keyed by path, so the two
  /// have to agree.
  @concurrent
  nonisolated private static func findPendingJobs(in directory: URL) async -> [(URL, String?)] {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
    else { return [] }
    return names.compactMap { name in
      let entry = directory.appendingPathComponent(name, isDirectory: true)
      guard let job = TranscriptionJob.load(for: entry) else { return nil }
      return (entry, job.lastError)
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
      case .serverError, .pollTimeout: return true
      case .uploadFailed, .transcriptionFailed: return false
      }
    }
    return false
  }

  /// 30s, 2m, 8m.
  nonisolated private static func backoff(forAttempt attempt: Int) -> Duration {
    .seconds(30 << (2 * max(0, attempt - 1)))
  }
}
