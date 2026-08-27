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
/// Each recording gets its own job and they run concurrently; only the local
/// mix is bounded, by `Dependencies.uploadConcurrency`. Everything is
/// best-effort: a failure here never touches the recording, and nothing on this
/// path is allowed to extend `applicationShouldTerminate`'s budget - an
/// interrupted job resumes on the next launch from its sidecar.
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
    /// How many jobs may be inside `upload` at once. `upload` is where the mix
    /// lives, and a mix writes a full-size copy of the recording to the temp
    /// directory, so this is a disk bound as much as a CPU one. Two keeps peak
    /// scratch at four recording-sized files while still overlapping one job's
    /// network transmit with another's encode.
    var uploadConcurrency: Int = 2
  }

  // MARK: - Upload Gate

  private struct UploadWaiter {
    let id: UUID
    let continuation: CheckedContinuation<UploadSlot, Never>
  }

  @ObservationIgnored private var uploadSlotsInUse = 0
  @ObservationIgnored private var uploadWaiters: [UploadWaiter] = []

  /// True when the caller owns a slot and must release it. False means the wait
  /// was cancelled and the caller must not proceed to upload.
  ///
  /// Deliberately not an actor. Actor isolation is mutual exclusion across
  /// *synchronous* regions, and `mix` awaits `AVAssetExportSession.export`,
  /// which releases the actor and lets the next caller straight in - so an
  /// actor would bound nothing at all. The coordinator already runs wholly on
  /// the main actor, which is what makes two variables sufficient here.
  private enum UploadSlot {
    case acquired
    case cancelled
    /// Quit began while this job was waiting. Distinct from `cancelled`,
    /// because a cancelled job discards its record and a suspended one has to
    /// keep it - that sidecar is what the next launch resumes from.
    case suspended
  }

  private func acquireUploadSlot() async -> UploadSlot {
    guard !Task.isCancelled else { return .cancelled }
    // Checked here as well as in the hand-off: a job can arrive at the gate
    // *after* quit begins - out of `durationSeconds`, or waking from eight
    // minutes of backoff - and would otherwise take the fast path below and
    // start a POST the process kill is about to cut.
    guard !isSuspended else { return .suspended }
    if uploadSlotsInUse < dependencies.uploadConcurrency {
      uploadSlotsInUse += 1
      return .acquired
    }
    let id = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<UploadSlot, Never>) in
        uploadWaiters.append(UploadWaiter(id: id, continuation: continuation))
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.abandonUploadWaiter(id) }
    }
  }

  /// A waiter that has already been handed a slot is no longer in the array, so
  /// a cancel landing after the hand-off finds nothing and returns. That is what
  /// makes a double resume impossible.
  private func abandonUploadWaiter(_ id: UUID) {
    guard let index = uploadWaiters.firstIndex(where: { $0.id == id }) else { return }
    uploadWaiters.remove(at: index).continuation.resume(returning: .cancelled)
  }

  /// Hands the slot straight to the head waiter rather than decrementing, so
  /// the count never dips and a job arriving between the release and the
  /// wake-up cannot jump the queue.
  private func releaseUploadSlot() {
    if uploadWaiters.isEmpty {
      uploadSlotsInUse -= 1
      return
    }
    // Nothing new starts once quit has begun. `suspendNewJobs` only guarded
    // `enqueue`, so a job already parked here was handed a slot during the 8s
    // termination window and began a POST the process kill then cut - the exact
    // outcome that flag exists to prevent.
    guard !isSuspended else {
      uploadSlotsInUse -= 1
      let waiting = uploadWaiters
      uploadWaiters.removeAll()
      for waiter in waiting { waiter.continuation.resume(returning: .suspended) }
      return
    }
    uploadWaiters.removeFirst().continuation.resume(returning: .acquired)
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
  /// How many times each recording's job has reached a terminal state.
  ///
  /// This replaced a single `lastFinishedPath`, which could only name one
  /// recording. With concurrent jobs, A finishing and then B finishing before
  /// SwiftUI drains the change leaves the variable reading B, `revision` bumped
  /// twice, and A's open detail view never reloading its transcript - silently,
  /// forever. A per-path counter cannot coalesce that way, because `onChange`
  /// compares the value it is watching.
  private var finishCounts: [String: Int] = [:]

  func finishCount(for recordingDirectory: URL) -> Int {
    finishCounts[recordingDirectory.path] ?? 0
  }

  private var statuses: [String: TranscriptionStatus] = [:]

  /// One task per recording directory, keyed by the same path `statuses` uses -
  /// so "is this job in flight" and "what is this job's status" cannot
  /// disagree.
  ///
  /// This replaced a global queue plus a single `activeDirectory`. Jobs are
  /// almost entirely *waiting*: a mix, an upload, then a poll loop against
  /// Soniox that can run for a minute or more and contends with nothing. Making
  /// them share one slot meant a recording finished at 17:52 did not start
  /// transcribing until 18:17, because a call that began one second later ran
  /// for 23 minutes. Only the local mix deserves a bound, and it has its own.
  ///
  /// `@ObservationIgnored` because nothing observes it, and a dictionary of
  /// tasks would otherwise fire a SwiftUI invalidation per job start.
  @ObservationIgnored private var jobs: [String: Task<Void, Never>] = [:]

  /// Set when the app is terminating. New work still writes its sidecar and
  /// shows as queued, so `resumePendingJobs()` picks it up next launch - but
  /// nothing starts an upload the process kill is about to interrupt
  /// mid-flight, which would strand the audio on Soniox with no local record of
  /// it. Running jobs are deliberately not cancelled: cancelling would drop them
  /// and delete remote artifacts for work that would otherwise resume.
  @ObservationIgnored private var isSuspended = false

  func suspendNewJobs() { isSuspended = true }

  @ObservationIgnored private let dependencies: Dependencies
  /// Outer nil means "not read yet". Cached because `hasAPIKey` is read from a
  /// SwiftUI body that re-evaluates at playback tick rate, and reading the key
  /// is a synchronous Keychain round-trip.
  @ObservationIgnored private var cachedAPIKey: String??

  private static let maxAttempts = 3
  /// Offline waits do not spend an attempt, so they get their own bound.
  private static let maxOfflineWaits = 60
  private static let offlineRetry = Duration.seconds(60)
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

  /// Folds an upload-phase report into the status. Called from a detached hop,
  /// so it drops anything for a job that has since moved on rather than
  /// resurrecting a stale stage over a newer one.
  private func recordUploadProgress(_ phase: TranscriptionUploadPhase, for key: String) {
    // `.cancelling` is `isActive`, so without excluding it the next progress
    // tick - `mix` reports every 0.5s, and a long mix runs for minutes -
    // overwrote the status `cancel()` had just set, re-enabling the Cancel
    // button and restoring a moving bar. That is precisely the dead-control
    // behaviour the synchronous write in `cancel()` exists to prevent.
    guard let current = statuses[key], current.isActive, current != .cancelling else { return }
    switch phase {
    case .mixing(let fraction): statuses[key] = .mixing(fraction: fraction)
    case .uploading(let fraction): statuses[key] = .uploading(fraction: fraction)
    }
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
  ///
  /// Resume runs again on the way out, because it is gated on a key and had
  /// only one caller - launch. A user who starts the app with no key, then
  /// pastes one, otherwise leaves every interrupted job and every
  /// `awaitingRemoteDelete` marker untouched for the rest of the session. Those
  /// markers are the mechanism that gets already-uploaded call audio back off
  /// Soniox, so "until the next launch" is the wrong deadline for them.
  func apiKeyChanged() {
    cachedAPIKey = nil
    guard apiKey() != nil else { return }
    resumePendingJobs(sweepScratchFiles: false)
  }

  // MARK: - Triggers

  /// Auto-trigger for a finished recording. `audioFileURL` is what
  /// `AudioRecorder.stop()` hands back; the job is keyed by its directory.
  /// `recordingDirectory` is exactly what `RecorderSession.stop()` returns.
  /// An earlier version took the audio file and climbed to its parent, which
  /// silently enqueued the whole recordings folder: every job then keyed on
  /// that one path, so the list showed nothing for the actual recording, the
  /// next recording deduped against it, and `RecordingStore.audioURL(in:)`
  /// transcribed whatever stray audio happened to sit at the top level.
  func recordingFinished(recordingDirectory: URL) {
    guard dependencies.isAutoEnabled() else { return }
    guard apiKey() != nil else {
      Log.info(
        Log.transcription, "transcription",
        "auto-transcribe is on but no API key is configured; skipping")
      return
    }
    // A recording directory always sits directly inside the save directory.
    // Anything else means the caller handed over the wrong level, and the cost
    // of acting on it is the user's money and a stranger's audio on Soniox.
    let saveDirectory = dependencies.saveDirectory()
    guard recordingDirectory.deletingLastPathComponent().path == saveDirectory.path else {
      // Ordinarily this means the save folder changed while the recording was
      // running: the recorder captured its directory at construction, so the
      // finished recording is in the old folder and this refuses it. It is not
      // a caller error, which is what the old wording said.
      Log.info(
        Log.transcription, "transcription",
        "not auto-transcribing \(recordingDirectory.lastPathComponent): it is not in the current save folder (\(saveDirectory.path))"
      )
      return
    }
    enqueue(recordingDirectory, isAutomatic: true)
  }

  /// Manual trigger from the recording detail view, including retry after a
  /// failure. An explicit request is a fresh start: any recorded failure is
  /// cleared and the retry budget is reset, whatever earlier runs spent. Not
  /// conditional on `lastError` - the offline give-up path leaves a job with
  /// spent attempts and no recorded error, and a Retry there must not go
  /// terminal on the first hiccup.
  func transcribe(recordingDirectory: URL) {
    guard apiKey() != nil else { return }
    // The reset below dispatches remote DELETEs and clears the sidecar's ids,
    // and `enqueue`'s in-flight guard is downstream of it - so a request for a
    // directory whose job is still running used to destroy that job's remote
    // artifacts and erase its ids, then start nothing. Only four view-level
    // `.disabled` conditions kept that unreachable.
    //
    // Scoped to this block rather than the whole method: `enqueue` still has to
    // run, because it is what downgrades the automatic flag on a job the user
    // has now asked for by hand, and that has to work while one is in flight.
    if jobs[recordingDirectory.path] == nil,
      var job = TranscriptionJob.load(for: recordingDirectory)
    {
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
          // Cleared on dispatch rather than on confirmation, unlike every other
          // path here: the user is starting a new run, and a record still
          // naming the old transcription would have that run polling ids this
          // very click is deleting. A delete that then fails is logged and its
          // artifacts orphaned - the one place that trade is made, and only on
          // an explicit user action.
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

  /// Discards a recording's job using a record captured *before* the directory
  /// was moved. `cancel` reads the sidecar by path, so calling it after the
  /// trash gets an empty job, and an empty job has no ids to delete - which
  /// left the uploaded audio on Soniox with nothing naming it.
  func forgetDeletedRecording(recordingDirectory: URL, job: TranscriptionJob?) {
    jobs[recordingDirectory.path]?.cancel()
    jobs[recordingDirectory.path] = nil
    statuses[recordingDirectory.path] = nil
    guard let job else { return }
    _ = discardRemote(job: job)
  }

  func cancel(recordingDirectory: URL) {
    if let task = jobs[recordingDirectory.path] {
      // Marked synchronously. Cancellation is only observed at the next
      // suspension point, and an upload can sit inside one for minutes, so
      // without this the button stayed live and the spinner unchanged - which
      // reads as a dead control and gets clicked again.
      statuses[recordingDirectory.path] = .cancelling
      task.cancel()
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
  /// `sweepScratchFiles` is only safe at launch. The sweep deletes by the
  /// `blackbox-mixed-` / `blackbox-upload-` prefixes, which are exactly the
  /// names a running job is writing, so sweeping mid-session unlinks the mix or
  /// the multipart body out from under an in-flight upload.
  func resumePendingJobs(sweepScratchFiles: Bool = true) {
    guard apiKey() != nil else { return }
    let directory = dependencies.saveDirectory()
    let sweep = dependencies.sweepTemporaryFiles
    Task { [weak self] in
      if sweepScratchFiles { await sweep() }
      let pending = await Self.directoriesWithPendingJobs(in: directory)
      guard let self else { return }
      for recordingDirectory in pending {
        // Read fresh, and skip anything already in flight: the user can have
        // hit Retry on one of these while the sweep above was running.
        guard self.jobs[recordingDirectory.path] == nil else { continue }
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
          self.discardRemote(job: job) { Self.retireMarker(job, in: recordingDirectory) }
          continue
        }
        if let lastError = job.lastError {
          // A terminal failure keeps its ids when the cleanup could not be
          // dispatched at the time. Retry the delete, but keep the record
          // either way: the detail view still has to offer the retry.
          if job.fileId != nil || job.transcriptionId != nil {
            self.discardRemote(job: job) { Self.clearRemoteIds(job, in: recordingDirectory) }
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
    guard jobs[key] == nil else { return }
    if TranscriptionJob.load(for: recordingDirectory) == nil {
      TranscriptionJob(isAutomatic: isAutomatic).save(for: recordingDirectory)
    }
    statuses[key] = .queued
    // The sidecar is written either way, so a recording reported during quit is
    // picked up by the next launch rather than lost.
    guard !isSuspended else { return }
    jobs[key] = Task { [weak self] in await self?.run(recordingDirectory) }
  }

  // MARK: - Job Runner

  private func run(_ recordingDirectory: URL) async {
    let key = recordingDirectory.path
    let name = recordingDirectory.lastPathComponent
    // Inside `run`, not the task body: `run` is MainActor-isolated with no
    // suspension between its terminal `finish`/`drop`/`fail` and its return, so
    // this fires in the same main-actor turn as the terminal status write.
    // Clearing from the task body would put a suspension between "status is
    // terminal" and "slot is free", and retry-after-error would intermittently
    // hit the still-occupied guard.
    defer { jobs[key] = nil }

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
    // sit on the upload gate, in backoff, or in an hour of offline retries, and
    // the user can turn auto-transcribe off during any of them. Once Soniox has
    // been billed (`transcriptionId`) the money is spent and finishing is better.
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
          statuses[key] = .queued
          switch await acquireUploadSlot() {
          case .acquired:
            break
          case .cancelled:
            Log.info(
              Log.transcription, "transcription",
              "cancelled \(name) while waiting to upload")
            drop(job: job, in: recordingDirectory)
            return
          case .suspended:
            // Sidecar deliberately left in place: this is the quit path, and
            // the next launch resumes from it. Dropping here would delete the
            // record `suspendNewJobs` exists to preserve.
            Log.info(
              Log.transcription, "transcription",
              "deferring \(name) to the next launch: quit began while it waited to upload")
            return
          }
          defer { releaseUploadSlot() }
          // The fifth consent point. A job can now wait behind up to N other
          // uploads, each of them minutes long, and without a check here that
          // wait would be the one window in the whole pipeline with no consent
          // re-check in it.
          if isConsentWithdrawn(for: job) {
            Log.info(
              Log.transcription, "transcription",
              "dropping auto-transcription for \(name) before uploading: the setting is now off")
            drop(job: job, in: recordingDirectory)
            return
          }
          statuses[key] = .mixing(fraction: 0)
          job.fileId = try await service.upload(fileURL: audioURL) { [weak self] phase in
            Task { @MainActor [weak self] in
              self?.recordUploadProgress(phase, for: key)
            }
          }
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
        // on disk that could name it. No test covers that race directly - one
        // would have to hit a window between an HTTP response and the next
        // executor hop - so this is defended by sharing `discardRemote` with the
        // cancellation path, which is covered.
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
          statuses[key] = .offline
          await dependencies.sleep(duration)

        case .retry(let duration):
          job.attempts += 1
          job.save(for: recordingDirectory)
          statuses[key] = .retrying(attempt: job.attempts, of: Self.maxAttempts)
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

  /// The automatic-transcription rule, in one place because it is applied at
  /// five points: at resume so a switched-off job never starts, on entry to
  /// `run`, on every pass of the job loop, again immediately after acquiring an
  /// upload slot, and again immediately before the call that bills. The waits
  /// between those points are long - an upload of a long call, eight minutes of
  /// backoff, an hour of offline retries - and the user can reach Settings
  /// during any of them. False once Soniox has been billed: the money is spent,
  /// and finishing beats throwing away a transcript already paid for.
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
    finishCounts[key, default: 0] += 1
    revision += 1
  }

  /// Abandons a job without calling it a failure: the recording went away, the
  /// audio is too short to bill for, consent was withdrawn, or the user
  /// cancelled. Whatever the job already put on Soniox goes with it.
  private func drop(job: TranscriptionJob, in recordingDirectory: URL) {
    releaseRemoteRecord(job, in: recordingDirectory)
    statuses.removeValue(forKey: recordingDirectory.path)
  }

  /// Retires a job's local record, but not before Soniox has confirmed the
  /// delete. Until then the record stands as a delete-only marker, because
  /// those ids are the last trace of what is sitting there. Every path that
  /// finishes with a job - success, abandonment, cancellation - goes through
  /// here, so a crash between the two leaves a marker the next launch retries.
  private func releaseRemoteRecord(_ job: TranscriptionJob, in recordingDirectory: URL) {
    var pending = job
    pending.awaitingRemoteDelete = true
    pending.lastError = nil
    pending.save(for: recordingDirectory)
    discardRemote(job: job) { Self.retireMarker(job, in: recordingDirectory) }
  }

  /// Removes a delete-only marker, but only if it is still the same one. The
  /// user can start a fresh job for this recording while the delete is in
  /// flight, and that job's sidecar must not be taken out from under it.
  private static func retireMarker(_ job: TranscriptionJob, in recordingDirectory: URL) {
    guard let current = TranscriptionJob.load(for: recordingDirectory),
      current.awaitingRemoteDelete,
      current.fileId == job.fileId,
      current.transcriptionId == job.transcriptionId
    else { return }
    TranscriptionJob.remove(for: recordingDirectory)
  }

  /// Clears the ids from a record that outlives its job - a terminal failure
  /// keeps its sidecar so the detail view can offer a retry. Same identity
  /// check as `retireMarker`, for the same reason.
  private static func clearRemoteIds(_ job: TranscriptionJob, in recordingDirectory: URL) {
    guard var current = TranscriptionJob.load(for: recordingDirectory),
      current.fileId == job.fileId,
      current.transcriptionId == job.transcriptionId
    else { return }
    current.fileId = nil
    current.transcriptionId = nil
    current.save(for: recordingDirectory)
  }

  /// Terminal outcome: surface it and keep the sidecar so the detail view can
  /// offer a retry, but drop what the job already put on Soniox. A failed job
  /// the user never retries would otherwise leave the call audio there for good.
  private func fail(_ job: inout TranscriptionJob, in recordingDirectory: URL, message: String) {
    // The ids survive in the record until the delete is confirmed; they are the
    // only trace of what is on Soniox, and a failed cleanup has to be retryable
    // at the next launch.
    let attempted = job
    job.lastError = message
    job.save(for: recordingDirectory)
    discardRemote(job: attempted) { Self.clearRemoteIds(attempted, in: recordingDirectory) }
    finish(key: recordingDirectory.path, status: .error(message))
  }

  /// Deletes whatever a job put on Soniox. Detached from the caller so it still
  /// runs when the job's own task was the thing that got cancelled.
  ///
  /// Returns false when the delete could not even be dispatched, which happens
  /// when there is no API key - the user cleared or rotated it while a job held
  /// remote artifacts. Callers must not destroy the job's ids in that case: the
  /// sidecar is the only thing left that names what is sitting on Soniox.
  ///
  /// `onDeleted` runs only once Soniox has confirmed every artifact is gone.
  /// Retiring the record on *dispatch* was the older shape and it lost the ids
  /// whenever the request then failed - a 401 from a half-typed key, or an
  /// offline machine - which are exactly the conditions a user is in while
  /// typing a key into Settings, the moment these markers get retried.
  @discardableResult
  private func discardRemote(
    job: TranscriptionJob, onDeleted: @escaping @MainActor () -> Void = {}
  ) -> Bool {
    let transcriptionIds = [job.transcriptionId].compactMap { $0 }
    let fileIds = [job.fileId].compactMap { $0 }
    guard !transcriptionIds.isEmpty || !fileIds.isEmpty else {
      onDeleted()
      return true
    }
    guard let apiKey = apiKey() else {
      Log.error(
        Log.transcription, "transcription",
        "cannot delete Soniox artifacts (file=\(fileIds.first ?? "none"), transcription=\(transcriptionIds.first ?? "none")): no API key configured. Keeping the job record so a later launch can finish the cleanup."
      )
      return false
    }
    let service = dependencies.makeService(apiKey)
    Task { @MainActor in
      let deleted = await service.deleteRemote(
        transcriptionIds: transcriptionIds, fileIds: fileIds)
      guard deleted else { return }
      onDeleted()
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
