import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import Blackbox

extension Duration {
  fileprivate var timeInterval: TimeInterval {
    let seconds = Double(components.seconds)
    let attoseconds = Double(components.attoseconds) / 1_000_000_000_000_000_000
    return seconds + attoseconds
  }
}

enum TestFixtures {
  static func recordingDirectory(named name: String) throws -> URL {
    let base = try #require(Bundle.module.resourceURL)
      .appendingPathComponent("Fixtures", isDirectory: true)
      .appendingPathComponent("Recordings", isDirectory: true)
    let directory = base.appendingPathComponent(name, isDirectory: true)
    try #require(
      FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)),
      "Fixture recording not found: \(name)")
    return directory
  }
}

enum HardwareSmokeError: Error, CustomStringConvertible {
  case missingAppPath
  case missingPermission(String)
  case launchFailed(String)
  case systemAudioPlaybackFailed(String)
  case timedOut(String)

  var description: String {
    switch self {
    case .missingAppPath:
      "BLACKBOX_SMOKE_APP_PATH is not set or does not exist"
    case .missingPermission(let detail):
      detail
    case .launchFailed(let detail):
      "Failed to launch smoke app: \(detail)"
    case .systemAudioPlaybackFailed(let detail):
      "Failed to play smoke system audio: \(detail)"
    case .timedOut(let detail):
      "Timed out waiting for smoke state: \(detail)"
    }
  }
}

@MainActor
final class TestClock: @unchecked Sendable {
  private struct PendingSleep {
    let wakeTime: Date
    let continuation: CheckedContinuation<Void, Never>
  }

  private var currentDate: Date
  private var pendingSleeps: [PendingSleep] = []

  init(now: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
    currentDate = now
  }

  func now() -> Date { currentDate }

  func sleep(for duration: Duration) async {
    let timeInterval = duration.timeInterval
    guard timeInterval > 0 else { return }
    let wakeTime = currentDate.addingTimeInterval(timeInterval)
    await withCheckedContinuation { continuation in
      pendingSleeps.append(PendingSleep(wakeTime: wakeTime, continuation: continuation))
    }
  }

  func advance(by duration: Duration) {
    currentDate = currentDate.addingTimeInterval(duration.timeInterval)
    resumeReadySleeps()
  }

  private func resumeReadySleeps() {
    var remaining: [PendingSleep] = []
    for sleep in pendingSleeps {
      if sleep.wakeTime <= currentDate {
        sleep.continuation.resume()
      } else {
        remaining.append(sleep)
      }
    }
    pendingSleeps = remaining
  }
}

@MainActor
final class FakeHUD: AudioMonitorHUD {
  private(set) var startedApps: [String] = []
  private(set) var savedApps: [String] = []
  private(set) var errors: [String] = []
  private(set) var lastToast: HUDToast?

  func showRecordingStarted(appName: String) {
    startedApps.append(appName)
    record(title: HUDToast.startedTitle, subtitle: appName)
  }

  func showRecordingSaved(appName: String) {
    savedApps.append(appName)
    record(title: HUDToast.savedTitle, subtitle: appName)
  }

  private(set) var finalizingCount = 0

  func showFinalizing() {
    finalizingCount += 1
    record(title: HUDToast.finalizingTitle, subtitle: "")
  }

  func showError(message: String) {
    errors.append(message)
    record(title: HUDToast.errorTitle, subtitle: message)
  }

  private func record(title: String, subtitle: String) {
    lastToast = HUDToast(title: title, subtitle: subtitle)
  }
}

/// Async gate used by AudioRecorder race tests to deterministically suspend
/// `start()` at a specific checkpoint, run a stop() against the same actor,
/// and then release. Two-sided rendezvous: one waiter on the start side
/// (suspending the recorder), one on the test side (waiting until the
/// recorder has actually entered the suspended state).
actor StartGate {
  private var suspended: CheckedContinuation<Void, Never>?
  private var observer: CheckedContinuation<Void, Never>?
  private var didSuspend = false
  private var didRelease = false

  func suspend() async {
    didSuspend = true
    if let observer {
      observer.resume()
      self.observer = nil
    }
    if didRelease { return }
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      suspended = cont
    }
  }

  func waitForSuspended() async {
    if didSuspend { return }
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      observer = cont
    }
  }

  func release() {
    didRelease = true
    let s = suspended
    suspended = nil
    s?.resume()
  }
}

@MainActor
final class TestRecorderSession: RecorderSession {
  let configuration: RecorderSessionConfiguration

  var startError: Error?
  var stopURL: URL?
  /// When true, `start()` suspends on a CheckedContinuation and waits for
  /// `releaseStart()`. Lets tests deterministically interleave a stop()
  /// arriving while start() is in flight.
  var suspendStart = false
  private(set) var startCallCount = 0
  private(set) var stopCallCount = 0
  private var startSuspension: CheckedContinuation<Void, Never>?

  private let onFailure: (@Sendable (RecorderFailure) -> Void)?
  private let onContinuity: (@Sendable () -> Void)?

  init(
    configuration: RecorderSessionConfiguration,
    onFailure: (@Sendable (RecorderFailure) -> Void)?,
    onContinuity: (@Sendable () -> Void)?
  ) {
    self.configuration = configuration
    self.onFailure = onFailure
    self.onContinuity = onContinuity
  }

  var appName: String { configuration.appName }

  func start() async throws {
    startCallCount += 1
    if suspendStart {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        startSuspension = continuation
      }
    }
    if let startError { throw startError }
  }

  func releaseStart() {
    let cont = startSuspension
    startSuspension = nil
    cont?.resume()
  }

  func stop() async -> URL? {
    stopCallCount += 1
    return stopURL
  }

  func emitFailure(_ failure: RecorderFailure) {
    onFailure?(failure)
  }

  func emitContinuityEvent() {
    onContinuity?()
  }
}

@MainActor
final class TestRecorderFactory: RecorderSessionFactory {
  private(set) var createdSessions: [TestRecorderSession] = []
  var nextStartError: Error?
  var stopURL: URL?
  /// If true, the next created session will suspend in `start()` until the
  /// test calls `releaseStart()` on it. One-shot - resets after the next
  /// session is produced.
  var nextSuspendStart = false

  func makeRecorder(
    configuration: RecorderSessionConfiguration,
    onFailure: (@Sendable (RecorderFailure) -> Void)?,
    onAudioLevel: (@Sendable (Float) -> Void)?,
    onLowDiskSpace: (@Sendable (Int64) -> Void)?,
    onContinuity: (@Sendable () -> Void)?
  ) -> any RecorderSession {
    let session = TestRecorderSession(
      configuration: configuration,
      onFailure: onFailure,
      onContinuity: onContinuity
    )
    session.startError = nextStartError
    session.stopURL = stopURL
    session.suspendStart = nextSuspendStart
    createdSessions.append(session)
    nextStartError = nil
    nextSuspendStart = false
    return session
  }
}

@MainActor
final class MonitorHarness {
  let clock = TestClock()
  let hud = FakeHUD()
  let recorderFactory = TestRecorderFactory()

  var settings = AudioMonitorSettings(
    autoRecord: true,
    gracePeriod: 5,
    micEnabled: true,
    saveDirectory: FileManager.default.temporaryDirectory,
    notifyOnStart: true,
    notifyOnSaved: true,
    notifyOnError: true
  )
  var activeCallers: [String?] = []
  var micAuthorizationStatus: AVAuthorizationStatus = .authorized
  private(set) var permissionLostNotifications = 0
  private(set) var savedRecordings: [URL] = []

  func makeMonitor() -> AudioMonitor {
    AudioMonitor(
      dependencies: AudioMonitorDependencies(
        recorderFactory: recorderFactory,
        hud: hud,
        loadSettings: { [weak self] in
          self?.settings
            ?? AudioMonitorSettings(
              autoRecord: true,
              gracePeriod: 5,
              micEnabled: true,
              saveDirectory: FileManager.default.temporaryDirectory,
              notifyOnStart: true,
              notifyOnSaved: true,
              notifyOnError: true
            )
        },
        microphoneAuthorizationStatus: { [weak self] in
          self?.micAuthorizationStatus ?? .authorized
        },
        requestMicrophoneAccessIfNeeded: {},
        notifyPermissionLost: { [weak self] in
          self?.permissionLostNotifications += 1
        },
        findActiveCallingProcesses: { [weak self] in
          self?.activeCallers ?? []
        },
        now: { [clock] in
          clock.now()
        },
        sleep: { [clock] duration in
          await clock.sleep(for: duration)
        },
        onRecordingSaved: { [weak self] url in
          self?.savedRecordings.append(url)
        }
      ))
  }
}

@MainActor
final class BlackboxSmokeClient {
  let runID = UUID().uuidString
  let saveDirectory: URL
  let appURL: URL
  let controlDirectory: URL
  private let commandURL: URL
  private let stateURL: URL

  init() throws {
    guard
      let appPath = ProcessInfo.processInfo.environment["BLACKBOX_SMOKE_APP_PATH"],
      FileManager.default.fileExists(atPath: appPath)
    else {
      throw HardwareSmokeError.missingAppPath
    }

    // Fail with the sentence that fixes it. Without these the app launches,
    // never captures, and the wait for "recording started" dies on a timeout
    // that says nothing about permissions.
    guard CGPreflightScreenCaptureAccess() else {
      throw HardwareSmokeError.missingPermission(
        "Screen Recording permission is required. Grant it in System Settings > Privacy & Security > Screen & System Audio Recording, then retry."
      )
    }
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
      throw HardwareSmokeError.missingPermission(
        "Microphone permission is required. Grant it in System Settings > Privacy & Security > Microphone, then retry."
      )
    }

    appURL = URL(fileURLWithPath: appPath)
    saveDirectory = FileManager.default.temporaryDirectory
      .appending(path: "blackbox-hardware-smoke-\(runID)")
    try FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)
    controlDirectory = saveDirectory.appending(path: ".blackbox-test-control")
    commandURL = controlDirectory.appending(path: "command.json")
    stateURL = controlDirectory.appending(path: "state.json")
  }

  func launch() throws {
    terminateRunningApps()

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [
      "-n",
      appURL.path,
      "--args",
      "--ui-test-mode",
      "--test-run-id",
      runID,
      "--test-save-directory",
      saveDirectory.path,
      // NSArgumentDomain outranks every persisted domain, so this pins the
      // setting for the launched process without touching what the developer
      // has stored. Transcription is the one setting the app under test still
      // reads from the real defaults - the rest are already replaced wholesale
      // by the test-mode branch of `AudioMonitorDependencies.live.loadSettings`.
      "-\(SettingsKeys.autoTranscribe)",
      "NO",
    ]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw HardwareSmokeError.launchFailed("open exit status \(process.terminationStatus)")
    }
  }

  func post(_ command: BlackboxTestCommand) {
    let request = BlackboxTestRequest(requestID: UUID().uuidString, command: command)
    guard let data = try? JSONEncoder().encode(request) else { return }
    try? FileManager.default.createDirectory(
      at: controlDirectory, withIntermediateDirectories: true)
    try? data.write(to: commandURL, options: .atomic)
  }

  func queryState() async throws -> BlackboxTestSnapshot {
    let stateURL = self.stateURL
    return try await withTimeout(seconds: 2.0, message: "queryState response") {
      while true {
        if let data = try? Data(contentsOf: stateURL),
          let response = try? JSONDecoder().decode(BlackboxTestResponse.self, from: data)
        {
          return response.snapshot
        }
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
  }

  func waitUntil(
    description: String,
    timeoutSeconds: TimeInterval = 15,
    predicate: @escaping (BlackboxTestSnapshot) -> Bool
  ) async throws -> BlackboxTestSnapshot {
    let start = Date()
    while Date().timeIntervalSince(start) < timeoutSeconds {
      // Transient queryState failures are recoverable while the outer deadline
      // has not elapsed - e.g. IPC state.json briefly unreadable under parallel
      // test load. Only the outer timeout should fail the wait.
      if let snapshot = try? await queryState(), predicate(snapshot) {
        return snapshot
      }
      try? await Task.sleep(for: .milliseconds(250))
    }
    throw HardwareSmokeError.timedOut(description)
  }

  func newestRecordingDirectory() throws -> URL {
    let contents = try FileManager.default.contentsOfDirectory(
      at: saveDirectory,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]
    )
    return try #require(
      contents.max { lhs, rhs in
        let lhsDate =
          (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
          ?? .distantPast
        let rhsDate =
          (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
          ?? .distantPast
        return lhsDate < rhsDate
      }, "Expected a recording directory in \(saveDirectory.path)")
  }

  func terminate() {
    post(.terminateApp)
    terminateRunningApps()
  }

  func playSystemAudioFixture() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
    process.arguments = ["/System/Library/Sounds/Glass.aiff"]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw HardwareSmokeError.systemAudioPlaybackFailed(
        "afplay exit status \(process.terminationStatus)")
    }
  }

  private func terminateRunningApps() {
    // Kill any Blackbox instance - including an installed /Applications copy -
    // so two tap/aggregate owners don't contend for the same system audio.
    for app in NSRunningApplication.runningApplications(
      withBundleIdentifier: "com.tenequm.Blackbox")
    {
      app.terminate()
    }
  }

  private func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    message: String,
    operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask {
        try await operation()
      }
      group.addTask {
        try await Task.sleep(for: .seconds(seconds))
        throw HardwareSmokeError.timedOut(message)
      }

      let result = try await group.next()!
      group.cancelAll()
      return result
    }
  }
}
