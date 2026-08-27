import AVFoundation
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
  /// The job itself is over; this record survives only because its remote
  /// artifacts could not be deleted yet. Resume retries the delete and never
  /// re-runs the job.
  var awaitingRemoteDelete: Bool = false

  static let fileName = "transcription-job.json"

  init(
    fileId: String? = nil, transcriptionId: String? = nil, attempts: Int = 0,
    isAutomatic: Bool = false, lastError: String? = nil, awaitingRemoteDelete: Bool = false
  ) {
    self.fileId = fileId
    self.transcriptionId = transcriptionId
    self.attempts = attempts
    self.isAutomatic = isAutomatic
    self.lastError = lastError
    self.awaitingRemoteDelete = awaitingRemoteDelete
  }

  /// Written by hand because the synthesized one does *not* fall back to a
  /// property's default when its key is absent - it throws. Combined with the
  /// `try?` in `load`, adding a field would silently orphan every sidecar a
  /// previous build wrote, and orphaning a sidecar strands the audio it names
  /// on Soniox with nothing left to identify it. Every key is optional here so
  /// the format stays additive.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    fileId = try container.decodeIfPresent(String.self, forKey: .fileId)
    transcriptionId = try container.decodeIfPresent(String.self, forKey: .transcriptionId)
    attempts = try container.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
    isAutomatic = try container.decodeIfPresent(Bool.self, forKey: .isAutomatic) ?? false
    lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
    awaitingRemoteDelete =
      try container.decodeIfPresent(Bool.self, forKey: .awaitingRemoteDelete) ?? false
  }

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

  /// Failures are logged rather than swallowed: this record is the only thing
  /// naming what a job has put on Soniox, so losing a write is how audio ends up
  /// stranded there with nothing left to identify it.
  func save(for recordingDirectory: URL) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
      let data = try encoder.encode(self)
      try data.write(to: Self.url(for: recordingDirectory), options: .atomic)
    } catch {
      Log.error(
        Log.transcription, "transcription",
        "failed to write the transcription job record for \(recordingDirectory.lastPathComponent): \(error.localizedDescription)"
      )
    }
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
          UserDefaults.standard.string(forKey: SettingsKeys.sonioxModel)))
    }
    var apiKey: () -> String? = {
      let key = KeychainHelper.string(forKey: SettingsKeys.sonioxAPIKey) ?? ""
      return key.isEmpty ? nil : key
    }
    var isAutoEnabled: () -> Bool = {
      UserDefaults.standard.bool(forKey: SettingsKeys.autoTranscribe)
    }
    /// Honours the `--ui-test-mode` override for the same reason
    /// `AudioMonitorDependencies.live` does: otherwise the recorder writes to
    /// the override directory while resume scans the user's real one.
    var saveDirectory: () -> URL = {
      BlackboxTestMode.saveDirectoryOverride
        ?? URL(
          fileURLWithPath: UserDefaults.standard.string(forKey: SettingsKeys.saveDirectoryPath)
            ?? defaultSaveDirectoryPath)
    }
    var sleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    var durationSeconds: @Sendable (URL) async -> Double? = {
      await TranscriptionCoordinator.assetDurationSeconds(of: $0)
    }
    /// Injectable so a test can occupy the window between `resumePendingJobs`
    /// starting and its scan landing - the window in which the user can act on
    /// a job that resume is about to look at.
    var sweepTemporaryFiles: @Sendable () async -> Void = {
      await TranscriptionService.sweepTemporaryFiles()
    }
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
  /// Which recording the latest `revision` belongs to. Without it a detail view
  /// re-decodes its own transcript every time any *other* recording finishes.
  private(set) var lastFinishedPath: String?

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
  /// Offline waits do not spend an attempt, so they get their own bound.
  private static let maxOfflineWaits = 60
  private static let offlineRetry = Duration.seconds(60)
  private static let recordingGate = Duration.seconds(30)
  /// Automatic jobs upload without asking, so a file too short to be a call is
  /// dropped rather than billed. In practice this catches an early manual stop
  /// and a recorder that died at startup; a false-positive *detection* always
  /// outlives it, because the grace period alone is clamped to 5s. Manual jobs
  /// are exempt: the user asked.
  private static let minimumAutomaticSeconds: Double = 3

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

  /// Manual trigger from the recording detail view, including retry after a
  /// failure. An explicit request is a fresh start: any recorded failure is
  /// cleared and the retry budget is reset, whatever earlier runs spent. Not
  /// conditional on `lastError` - the offline give-up path leaves a job with
  /// spent attempts and no recorded error, and a Retry there must not go
  /// terminal on the first hiccup.
  func transcribe(recordingDirectory: URL) {
    guard apiKey() != nil else { return }
    if var job = TranscriptionJob.load(for: recordingDirectory) {
      if job.awaitingRemoteDelete {
        // A cleanup left over from a session that had no key. There is one now
        // (guarded above), so it goes out immediately and the new job starts
        // from nothing rather than polling ids it is in the middle of deleting.
        _ = discardRemote(job: job)
        job = TranscriptionJob()
      } else {
        // A failure that could not dispatch its cleanup kept its ids. Retry
        // them now, so the new run starts fresh instead of re-polling a
        // transcription this same click is about to delete.
        if job.fileId != nil || job.transcriptionId != nil, discardRemote(job: job) {
          job.fileId = nil
          job.transcriptionId = nil
        }
        job.lastError = nil
        job.attempts = 0
      }
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
    drop(
      job: TranscriptionJob.load(for: recordingDirectory) ?? TranscriptionJob(),
      in: recordingDirectory)
  }

  /// Re-enqueues jobs left behind by a quit or a crash. Three things are
  /// deliberately not resumed: a job that already failed terminally (spending
  /// another upload is the user's call); an automatic job whose consent has
  /// since been withdrawn and that has not been billed yet, which is dropped
  /// and has its uploaded audio deleted rather than being left on Soniox; and
  /// nothing else. An automatic job that already holds a `transcriptionId` has
  /// been charged, so finishing it beats throwing away what was paid for.
  func resumePendingJobs() {
    guard apiKey() != nil else { return }
    let directory = dependencies.saveDirectory()
    let sweep = dependencies.sweepTemporaryFiles
    Task { [weak self] in
      await sweep()
      let pending = await Self.directoriesWithPendingJobs(in: directory)
      guard let self else { return }
      for recordingDirectory in pending {
        // Read fresh, and skip anything already in flight: the user can have
        // hit Retry on one of these while the sweep above was running.
        guard self.activeDirectory?.path != recordingDirectory.path,
          !self.queue.contains(where: { $0.path == recordingDirectory.path })
        else { continue }
        guard let job = TranscriptionJob.load(for: recordingDirectory) else {
          // `save` logs its write failures; this is the read side of that pair.
          // A record that will not decode is skipped on every launch, and its
          // ids are the only thing naming what may be sitting on Soniox.
          Log.error(
            Log.transcription, "transcription",
            "cannot read the transcription job record for \(recordingDirectory.lastPathComponent); it will be skipped on every launch and anything it uploaded stays on Soniox"
          )
          continue
        }
        let name = recordingDirectory.lastPathComponent
        if job.awaitingRemoteDelete {
          Log.info(
            Log.transcription, "transcription",
            "retrying Soniox cleanup left over from an earlier session for \(name)")
          if self.discardRemote(job: job) {
            TranscriptionJob.remove(for: recordingDirectory)
          }
          continue
        }
        if let lastError = job.lastError {
          // A terminal failure keeps its ids when the cleanup could not be
          // dispatched at the time. Retry the delete, but keep the record
          // either way: the detail view still has to offer the retry.
          if job.fileId != nil || job.transcriptionId != nil, self.discardRemote(job: job) {
            var cleared = job
            cleared.fileId = nil
            cleared.transcriptionId = nil
            cleared.save(for: recordingDirectory)
          }
          self.statuses[recordingDirectory.path] = .error(lastError)
          continue
        }
        if self.isConsentWithdrawn(for: job) {
          Log.info(
            Log.transcription, "transcription",
            "dropping pending auto-transcription for \(name): the setting is now off")
          self.drop(job: job, in: recordingDirectory)
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
    // Ahead of the in-flight guard on purpose: an explicit request has to
    // outrank the automatic flag even when an automatic job for the same
    // recording is already queued, or resume would later drop the job the user
    // asked for by hand.
    if !isAutomatic, var existing = TranscriptionJob.load(for: recordingDirectory),
      existing.isAutomatic
    {
      existing.isAutomatic = false
      existing.save(for: recordingDirectory)
    }
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

    // A sidecar that will not decode defaults to automatic, which is the
    // conservative reading for a consent gate: being wrong that way costs the
    // user another click, being wrong the other way spends their money.
    var job =
      TranscriptionJob.load(for: recordingDirectory) ?? TranscriptionJob(isAutomatic: true)

    guard let audioURL = RecordingStore.audioURL(in: recordingDirectory) else {
      Log.error(Log.transcription, "transcription", "no audio file in \(name), dropping job")
      drop(job: job, in: recordingDirectory)
      return
    }

    // Consent is re-checked here, not just where the job was created: a job can
    // sit behind the recording gate or another job for a long time, and the
    // user can turn auto-transcribe off in the meantime. Once Soniox has been
    // billed (`transcriptionId`) the money is spent and finishing is better.
    if isConsentWithdrawn(for: job) {
      Log.info(
        Log.transcription, "transcription",
        "dropping queued auto-transcription for \(name): the setting is now off")
      drop(job: job, in: recordingDirectory)
      return
    }

    if job.isAutomatic, job.transcriptionId == nil {
      // Fails closed on an unreadable duration. A container that will not open
      // is what a recorder that died on startup leaves behind, which is the
      // case this floor exists for - treating "cannot tell" as "long enough"
      // would let exactly those files through.
      let seconds = await dependencies.durationSeconds(audioURL)
      if seconds ?? 0 < Self.minimumAutomaticSeconds {
        let measured = seconds.map { String(format: "%.1fs", $0) } ?? "an unreadable duration"
        Log.info(
          Log.transcription, "transcription",
          "skipping auto-transcription for \(name): \(measured) is below the \(Int(Self.minimumAutomaticSeconds))s floor"
        )
        drop(job: job, in: recordingDirectory)
        return
      }
    }

    let service = dependencies.makeService(apiKey)
    var offlineWaits = 0

    while offlineWaits < Self.maxOfflineWaits {
      do {
        try Task.checkCancellation()
        // Re-checked every pass, not just before the loop: a `.wait` can sleep
        // for up to an hour of offline retries and a `.retry` for eight
        // minutes, and the user can withdraw consent during either. Checking
        // once on entry would let the next pass upload and bill anyway.
        if isConsentWithdrawn(for: job) {
          Log.info(
            Log.transcription, "transcription",
            "dropping in-flight auto-transcription for \(name): the setting is now off")
          drop(job: job, in: recordingDirectory)
          return
        }

        if job.fileId == nil {
          statuses[key] = .uploading
          job.fileId = try await service.upload(fileURL: audioURL)
          job.save(for: recordingDirectory)
        }
        // Checked again here rather than only at the top of the pass: `upload`
        // re-encodes and transmits the whole recording, which is minutes for a
        // long call, and this is the call that actually bills.
        if isConsentWithdrawn(for: job) {
          Log.info(
            Log.transcription, "transcription",
            "dropping auto-transcription for \(name) before billing: the setting is now off")
          drop(job: job, in: recordingDirectory)
          return
        }
        if job.transcriptionId == nil, let fileId = job.fileId {
          statuses[key] = .queued
          job.transcriptionId = try await service.createTranscription(
            fileId: fileId, reference: name)
          job.save(for: recordingDirectory)
        }
        guard let transcriptionId = job.transcriptionId else {
          fail(&job, in: recordingDirectory, message: "Soniox returned no transcription id")
          return
        }

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
          drop(job: job, in: recordingDirectory)
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

        // Deleted through `discardRemote` rather than awaited here: this task is
        // cancellable, and a cancel landing between the sidecar removal and the
        // DELETEs would strand the uploaded audio on Soniox with nothing left
        // on disk that could name it.
        releaseRemoteRecord(job, in: recordingDirectory)
        finish(key: key, status: .completed)
        Log.info(Log.transcription, "transcription", "transcribed \(name)")
        return
      } catch {
        switch failurePolicy(for: error, attempts: job.attempts) {
        case .cancelled:
          Log.info(Log.transcription, "transcription", "cancelled \(name)")
          drop(job: job, in: recordingDirectory)
          return

        case .wait(let duration):
          offlineWaits += 1
          statuses[key] = .queued
          await dependencies.sleep(duration)

        case .retry(let duration):
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

    // Out of offline waits. The sidecar stays resumable rather than terminal -
    // the last thing seen was a missing network, not a failure - but the status
    // is surfaced, because the audio may already be sitting on Soniox and a
    // silent `.idle` gives the user no sign of that.
    finish(key: key, status: .error("Offline - will retry on next launch"))
    Log.error(
      Log.transcription, "transcription",
      "gave up on \(name) for now; it will be retried on next launch")
  }

  /// The automatic-consent rule, in one place because it is applied at four
  /// points: at resume so a withdrawn job never joins the queue, on entry to
  /// `run`, on every pass of the job loop, and again immediately before the
  /// call that bills. The waits between those points are long - an upload of a
  /// long call, eight minutes of backoff, an hour of offline retries - and the
  /// user can reach Settings during any of them. False once Soniox has been
  /// billed: the money is spent, and finishing beats throwing away a transcript
  /// that has already been paid for.
  private func isConsentWithdrawn(for job: TranscriptionJob) -> Bool {
    job.isAutomatic && job.transcriptionId == nil && !dependencies.isAutoEnabled()
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
    lastFinishedPath = key
    revision += 1
  }

  /// Abandons a job without calling it a failure: the recording went away, the
  /// audio is too short to bill for, consent was withdrawn, or the user
  /// cancelled. Whatever the job already put on Soniox goes with it.
  private func drop(job: TranscriptionJob, in recordingDirectory: URL) {
    releaseRemoteRecord(job, in: recordingDirectory)
    statuses.removeValue(forKey: recordingDirectory.path)
  }

  /// Retires a job's local record. The record only goes away once something is
  /// on its way to delete what the job left on Soniox; otherwise it is kept as a
  /// delete-only marker, because those ids are the last trace of what is there.
  /// Every path that finishes with a job - success, abandonment, cancellation -
  /// goes through here.
  private func releaseRemoteRecord(_ job: TranscriptionJob, in recordingDirectory: URL) {
    if discardRemote(job: job) {
      TranscriptionJob.remove(for: recordingDirectory)
      return
    }
    var pending = job
    pending.awaitingRemoteDelete = true
    pending.lastError = nil
    pending.save(for: recordingDirectory)
  }

  /// Terminal outcome: surface it and keep the sidecar so the detail view can
  /// offer a retry, but drop what the job already put on Soniox. A failed job
  /// the user never retries would otherwise leave the call audio there for good.
  private func fail(_ job: inout TranscriptionJob, in recordingDirectory: URL, message: String) {
    // The ids are cleared only when something is actually on its way to delete
    // them, so a retry starts clean; otherwise they are the last record of what
    // is on Soniox and are kept for the cleanup pass at next launch.
    if discardRemote(job: job) {
      job.fileId = nil
      job.transcriptionId = nil
    }
    job.lastError = message
    job.save(for: recordingDirectory)
    finish(key: recordingDirectory.path, status: .error(message))
  }

  /// Deletes whatever a job put on Soniox. Detached from the caller so it still
  /// runs when the job's own task was the thing that got cancelled.
  ///
  /// Returns false when the delete could not even be dispatched, which happens
  /// when there is no API key - the user cleared or rotated it while a job held
  /// remote artifacts. Callers must not destroy the job's ids in that case: the
  /// sidecar is the only thing left that names what is sitting on Soniox.
  private func discardRemote(job: TranscriptionJob) -> Bool {
    let transcriptionIds = [job.transcriptionId].compactMap { $0 }
    let fileIds = [job.fileId].compactMap { $0 }
    guard !transcriptionIds.isEmpty || !fileIds.isEmpty else { return true }
    guard let apiKey = apiKey() else {
      Log.error(
        Log.transcription, "transcription",
        "cannot delete Soniox artifacts (file=\(fileIds.first ?? "none"), transcription=\(transcriptionIds.first ?? "none")): no API key configured. Keeping the job record so a later launch can finish the cleanup."
      )
      return false
    }
    let service = dependencies.makeService(apiKey)
    Task {
      await service.deleteRemote(transcriptionIds: transcriptionIds, fileIds: fileIds)
    }
    return true
  }

  // MARK: - Helpers

  /// Returns directories that hold a job record, not the records themselves.
  /// The enumeration is the expensive part and belongs off the main actor; the
  /// records are deliberately read back on it, because this runs after two
  /// awaits and anything the user did in that window has already rewritten
  /// them. Acting on a snapshot taken beforehand would clobber a live job.
  @concurrent
  nonisolated private static func directoriesWithPendingJobs(in directory: URL) async -> [URL] {
    RecordingStore.directories(in: directory).filter {
      FileManager.default.fileExists(atPath: TranscriptionJob.url(for: $0).path)
    }
  }

  @concurrent
  nonisolated static func assetDurationSeconds(of url: URL) async -> Double? {
    guard let duration = try? await AVURLAsset(url: url).load(.duration) else { return nil }
    let seconds = CMTimeGetSeconds(duration)
    return seconds.isFinite ? seconds : nil
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
    if let error = error as? TranscriptionError { return error.isRetryable }
    return false
  }

  /// 30s, 2m, 8m.
  nonisolated private static func backoff(forAttempt attempt: Int) -> Duration {
    .seconds(30 << (2 * max(0, attempt - 1)))
  }
}
