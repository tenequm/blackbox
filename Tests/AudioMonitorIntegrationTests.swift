import Foundation
import Testing

@testable import Blackbox

@Suite("AudioMonitor Integration")
struct AudioMonitorIntegrationTests {
  private func settle(times: Int = 6) async {
    for _ in 0..<times {
      await Task.yield()
    }
  }

  @Test("starts auto recording when a call becomes active")
  func startsAutoRecordingWhenCallBecomesActive() async throws {
    let harness = MonitorHarness()
    let monitor = harness.makeMonitor()

    monitor.startMonitoring(skipPermissionRequests: true)
    await settle()
    harness.activeCallers = ["com.example.Zoom"]
    harness.clock.advance(by: .seconds(3))
    await settle()

    #expect(harness.recorderFactory.createdSessions.count == 1)
    let session = try #require(harness.recorderFactory.createdSessions.first)
    #expect(session.configuration.bundleID == "com.example.Zoom")
    #expect(session.startCallCount == 1)
    #expect(monitor.isRecording)
    #expect(monitor.currentAppName == "Zoom")
    #expect(harness.hud.startedApps == ["Zoom"])

    await monitor.stopMonitoring()
  }

  @Test("recorder configuration carries the resolved name prefix")
  func recorderConfigurationCarriesNamePrefix() async throws {
    let harness = MonitorHarness()
    harness.settings.namePrefixTemplate = "YYMM-DD-"
    let monitor = harness.makeMonitor()

    monitor.startMonitoring(skipPermissionRequests: true)
    await settle()
    harness.activeCallers = ["com.example.Zoom"]
    harness.clock.advance(by: .seconds(3))
    await settle()

    let session = try #require(harness.recorderFactory.createdSessions.first)
    let expected = formatNamePrefix(template: "YYMM-DD-", date: harness.clock.now())
    #expect(!expected.isEmpty)
    #expect(session.configuration.titlePrefix == expected)

    await monitor.stopMonitoring()
  }

  @Test("manual recording blocks auto-recording while active")
  func manualRecordingBlocksAutoRecording() async {
    let harness = MonitorHarness()
    let monitor = harness.makeMonitor()

    monitor.startManualRecording()
    await settle()
    #expect(harness.recorderFactory.createdSessions.count == 1)
    #expect(monitor.isManualRecording)

    harness.activeCallers = ["com.example.Zoom"]
    monitor.startMonitoring(skipPermissionRequests: true)
    await settle()
    harness.clock.advance(by: .seconds(3))
    await settle()

    #expect(harness.recorderFactory.createdSessions.count == 1)
    #expect(monitor.isManualRecording)

    await monitor.stopMonitoring()
  }

  @Test("continuity events suppress transient inactive polls and avoid splits")
  func continuityEventSuppressesTransientInactivePolls() async throws {
    let harness = MonitorHarness()
    harness.settings.gracePeriod = 2
    let monitor = harness.makeMonitor()

    harness.activeCallers = ["com.example.Zoom"]
    monitor.startMonitoring(skipPermissionRequests: true)
    await settle()
    harness.clock.advance(by: .seconds(3))
    await settle()

    let session = try #require(harness.recorderFactory.createdSessions.first)
    session.emitContinuityEvent()
    harness.activeCallers = []

    harness.clock.advance(by: .seconds(3))
    await settle()
    #expect(session.stopCallCount == 0)
    #expect(monitor.graceCountdown == nil)
    #expect(monitor.isRecording)

    harness.activeCallers = ["com.example.Zoom"]
    harness.clock.advance(by: .seconds(3))
    await settle()
    #expect(session.stopCallCount == 0)
    #expect(monitor.graceCountdown == nil)
    #expect(harness.recorderFactory.createdSessions.count == 1)

    await monitor.stopMonitoring()
  }

  @Test("system-stopped failures restart up to the bounded budget")
  func recorderFailureRestartsWithinBudget() async throws {
    let harness = MonitorHarness()
    let monitor = harness.makeMonitor()

    harness.activeCallers = ["com.example.Zoom"]
    monitor.startMonitoring(skipPermissionRequests: true)
    await settle()
    harness.clock.advance(by: .seconds(3))
    await settle()

    for expectedCount in 2...4 {
      let current = try #require(harness.recorderFactory.createdSessions.last)
      current.emitFailure(.systemStopped)
      await settle()
      #expect(harness.recorderFactory.createdSessions.count == expectedCount)
    }

    let finalSession = try #require(harness.recorderFactory.createdSessions.last)
    finalSession.emitFailure(.systemStopped)
    await settle()

    #expect(harness.recorderFactory.createdSessions.count == 4)
    #expect(monitor.errorMessage == "Recording failed repeatedly")

    await monitor.stopMonitoring()
  }

  @Test("display loss restarts auto-recording without consuming the restart budget")
  func displayLostRestartsAutoRecordingUnbounded() async throws {
    let harness = MonitorHarness()
    let monitor = harness.makeMonitor()

    harness.activeCallers = ["com.example.Zoom"]
    monitor.startMonitoring(skipPermissionRequests: true)
    await settle()
    harness.clock.advance(by: .seconds(3))
    await settle()

    // The systemStopped budget is 3 restarts per 30s. Display sleep is not a
    // recorder fault: well past that many losses must still restart.
    for expectedCount in 2...8 {
      let current = try #require(harness.recorderFactory.createdSessions.last)
      current.emitFailure(.displayLost)
      await settle()
      #expect(harness.recorderFactory.createdSessions.count == expectedCount)
      #expect(monitor.isRecording, "auto-recording must resume after display loss")
    }
    #expect(monitor.errorMessage != "Recording failed repeatedly")

    await monitor.stopMonitoring()
  }

  @Test("display loss restarts manual recording")
  func displayLostRestartsManualRecording() async throws {
    let harness = MonitorHarness()
    let monitor = harness.makeMonitor()
    monitor.startMonitoring(skipPermissionRequests: true)
    await settle()

    monitor.startManualRecording()
    await settle()
    #expect(monitor.isManualRecording)
    #expect(harness.recorderFactory.createdSessions.count == 1)

    for expectedCount in 2...6 {
      let current = try #require(harness.recorderFactory.createdSessions.last)
      current.emitFailure(.displayLost)
      await settle()
      #expect(harness.recorderFactory.createdSessions.count == expectedCount)
      #expect(monitor.isManualRecording, "manual recording must resume after display loss")
    }

    monitor.stopManualRecording()
    await settle()
    await monitor.stopMonitoring()
  }

  @Test("multiple simultaneous callers records with nil bundleID")
  func multipleSimultaneousCallersRecordsWithNilBundleID() async throws {
    let harness = MonitorHarness()
    let monitor = harness.makeMonitor()

    // Start monitoring with no active callers
    monitor.startMonitoring(skipPermissionRequests: true)
    await settle()
    harness.clock.advance(by: .seconds(3))
    await settle()

    // Multiple callers appear on the next poll cycle
    harness.activeCallers = ["com.example.Zoom", "com.example.Chrome"]
    harness.clock.advance(by: .seconds(3))
    await settle()

    #expect(harness.recorderFactory.createdSessions.count == 1)
    let session = try #require(harness.recorderFactory.createdSessions.first)
    // When multiple callers are active, bundleID is nil (can't attribute to one app)
    #expect(session.configuration.bundleID == nil)
    #expect(monitor.isRecording)

    await monitor.stopMonitoring()
  }

  @Test("permissionDenied failure stops without restart and flags permission needed")
  func permissionDeniedStopsWithoutRestart() async throws {
    let harness = MonitorHarness()
    let monitor = harness.makeMonitor()

    harness.activeCallers = ["com.example.Zoom"]
    monitor.startMonitoring(skipPermissionRequests: true)
    await settle()
    harness.clock.advance(by: .seconds(3))
    await settle()

    let session = try #require(harness.recorderFactory.createdSessions.first)
    session.emitFailure(.permissionDenied)
    await settle()

    // No restart - session count stays at 1
    #expect(harness.recorderFactory.createdSessions.count == 1)
    #expect(monitor.permissionNeeded == true)
    #expect(harness.permissionLostNotifications == 1)
    #expect(!monitor.isRecording)

    await monitor.stopMonitoring()
  }

  @Test("lowDiskSpace failure stops with error and no restart")
  func lowDiskSpaceStopsWithError() async throws {
    let harness = MonitorHarness()
    let monitor = harness.makeMonitor()

    harness.activeCallers = ["com.example.Zoom"]
    monitor.startMonitoring(skipPermissionRequests: true)
    await settle()
    harness.clock.advance(by: .seconds(3))
    await settle()

    let session = try #require(harness.recorderFactory.createdSessions.first)
    session.emitFailure(.lowDiskSpace)
    await settle()

    #expect(harness.recorderFactory.createdSessions.count == 1)
    #expect(monitor.errorMessage != nil)
    #expect(!monitor.isRecording)

    await monitor.stopMonitoring()
  }

  @Test("inactive polling does not restart grace countdown forever")
  func inactivePollingDoesNotRestartGraceCountdownForever() async throws {
    let harness = MonitorHarness()
    let monitor = harness.makeMonitor()

    harness.activeCallers = ["com.example.Chrome"]
    monitor.startMonitoring(skipPermissionRequests: true)
    await settle()
    harness.clock.advance(by: .seconds(3))
    await settle()

    let session = try #require(harness.recorderFactory.createdSessions.first)
    #expect(monitor.isRecording)

    harness.activeCallers = []
    harness.clock.advance(by: .seconds(3))
    await settle()
    #expect(monitor.graceCountdown == nil)

    harness.clock.advance(by: .seconds(3))
    await settle()
    let countdownAfterStart = try #require(monitor.graceCountdown)
    #expect(countdownAfterStart <= 5.0)
    #expect(countdownAfterStart > 3.0)

    harness.clock.advance(by: .seconds(3))
    await settle()
    #expect(session.stopCallCount == 0)
    let countdownMidGrace = try #require(monitor.graceCountdown)
    #expect(countdownMidGrace < countdownAfterStart)

    harness.clock.advance(by: .seconds(3))
    await settle()
    #expect(session.stopCallCount == 1)
    #expect(!monitor.isRecording)
    #expect(monitor.graceCountdown == nil)

    await monitor.stopMonitoring()
  }

  @Test("stop during slow start cleans state without firing an error toast")
  func monitorStopDuringSlowFakeStart_cleanState() async throws {
    let harness = MonitorHarness()
    let monitor = harness.makeMonitor()

    harness.recorderFactory.nextSuspendStart = true
    harness.activeCallers = ["com.example.Chrome"]
    monitor.startMonitoring(skipPermissionRequests: true)
    await settle()
    harness.clock.advance(by: .seconds(3))
    await settle()

    let session = try #require(harness.recorderFactory.createdSessions.first)
    #expect(session.startCallCount == 1)

    // Drop the caller and let grace expire so the monitor calls stop()
    // while session.start() is still suspended.
    harness.activeCallers = []
    harness.clock.advance(by: .seconds(3))  // first inactive poll
    await settle()
    harness.clock.advance(by: .seconds(3))  // second inactive poll, grace begins
    await settle()
    harness.clock.advance(by: .seconds(6))  // grace expires
    await settle()

    #expect(session.stopCallCount >= 1)

    // Now release the suspended start. start() returns; monitor's identity
    // guard / silent-cancel branch should suppress the error toast.
    session.releaseStart()
    await settle()

    #expect(monitor.isRecording == false)
    #expect(monitor.errorMessage == nil, "no error toast for cancelled startup")
    #expect(harness.hud.errors.isEmpty)

    // Monitor should accept a fresh detection on next poll.
    harness.activeCallers = ["com.example.Chrome"]
    harness.clock.advance(by: .seconds(3))
    await settle()
    #expect(harness.recorderFactory.createdSessions.count == 2)

    await monitor.stopMonitoring()
  }

  @Test("manual stop suppresses auto-retry until the bundle disappears")
  func manualStopSuppressesAutoRetryUntilBundleInactive() async throws {
    let harness = MonitorHarness()
    let monitor = harness.makeMonitor()

    monitor.startMonitoring(skipPermissionRequests: true)
    await settle()

    // Helper bundle ID exercises parent-resolution path.
    harness.activeCallers = ["com.google.Chrome.helper.renderer"]
    monitor.startManualRecording()
    await settle()
    #expect(harness.recorderFactory.createdSessions.count == 1)
    #expect(monitor.isManualRecording)

    monitor.stopManualRecording()
    await settle()
    #expect(!monitor.isManualRecording)

    // Chrome still active; auto-record must NOT fire.
    harness.clock.advance(by: .seconds(3))
    await settle()
    #expect(harness.recorderFactory.createdSessions.count == 1)
    harness.clock.advance(by: .seconds(3))
    await settle()
    #expect(harness.recorderFactory.createdSessions.count == 1)

    // Chrome disappears -> suppression clears on the poll.
    harness.activeCallers = []
    harness.clock.advance(by: .seconds(3))
    await settle()
    #expect(harness.recorderFactory.createdSessions.count == 1)

    // Chrome reappears -> auto-record resumes.
    harness.activeCallers = ["com.google.Chrome.helper.renderer"]
    harness.clock.advance(by: .seconds(3))
    await settle()
    #expect(harness.recorderFactory.createdSessions.count == 2)

    await monitor.stopMonitoring()
  }

  @Test("suppression filters one bundle but lets other apps trigger auto-record")
  func suppressionDoesNotBlockOtherApps() async throws {
    let harness = MonitorHarness()
    let monitor = harness.makeMonitor()

    monitor.startMonitoring(skipPermissionRequests: true)
    await settle()

    harness.activeCallers = ["com.google.Chrome", "com.zoom.us"]
    monitor.startManualRecording()
    await settle()
    #expect(harness.recorderFactory.createdSessions.count == 1)

    monitor.stopManualRecording()
    await settle()

    // Chrome is suppressed; Zoom should still trigger auto-record.
    harness.clock.advance(by: .seconds(3))
    await settle()
    #expect(harness.recorderFactory.createdSessions.count == 2)
    let autoSession = try #require(harness.recorderFactory.createdSessions.last)
    #expect(autoSession.configuration.bundleID == "com.zoom.us")

    await monitor.stopMonitoring()
  }

  @Test("permissionDenied surfaces an error and is not silent-cancelled")
  func permissionDeniedStillSurfacesWhenNotCancel() async throws {
    let harness = MonitorHarness()
    let monitor = harness.makeMonitor()

    harness.recorderFactory.nextStartError = RecorderError.permissionDenied
    harness.activeCallers = ["com.example.Zoom"]
    monitor.startMonitoring(skipPermissionRequests: true)
    // Intentionally do not advance the clock here. setupCallDetection runs
    // synchronously and fires the failing start. Advancing the poll clock
    // would trigger a retry and clear permissionNeeded on a successful
    // second attempt, masking the assertion we want to make.
    await settle(times: 20)

    #expect(monitor.errorMessage != nil)
    #expect(monitor.permissionNeeded == true)

    await monitor.stopMonitoring()
  }

  // MARK: - Excluded Apps

  @Test("excluded app never triggers auto recording")
  func excludedAppDoesNotTriggerAutoRecording() async {
    let harness = MonitorHarness()
    harness.settings.excludedBundleIDs = ["com.example.Dictation"]
    let monitor = harness.makeMonitor()

    monitor.startMonitoring(skipPermissionRequests: true)
    await settle()
    harness.activeCallers = ["com.example.Dictation"]
    harness.clock.advance(by: .seconds(3))
    await settle()

    #expect(harness.recorderFactory.createdSessions.isEmpty)
    #expect(!monitor.isRecording)

    await monitor.stopMonitoring()
  }

  @Test("excluded app active at launch does not start recording")
  func excludedAppActiveAtLaunchDoesNotRecord() async {
    let harness = MonitorHarness()
    harness.settings.excludedBundleIDs = ["com.example.Dictation"]
    harness.activeCallers = ["com.example.Dictation"]
    let monitor = harness.makeMonitor()

    monitor.startMonitoring(skipPermissionRequests: true)
    await settle()

    #expect(harness.recorderFactory.createdSessions.isEmpty)
    #expect(!monitor.isRecording)

    await monitor.stopMonitoring()
  }

  @Test("exclusion is scoped to the excluded bundle ID")
  func exclusionDoesNotAffectOtherCallers() async throws {
    let harness = MonitorHarness()
    harness.settings.excludedBundleIDs = ["com.example.Dictation"]
    let monitor = harness.makeMonitor()

    monitor.startMonitoring(skipPermissionRequests: true)
    await settle()
    harness.activeCallers = ["com.example.Dictation", "com.example.Zoom"]
    harness.clock.advance(by: .seconds(3))
    await settle()

    #expect(harness.recorderFactory.createdSessions.count == 1)
    let session = try #require(harness.recorderFactory.createdSessions.first)
    #expect(session.configuration.bundleID == "com.example.Zoom")

    await monitor.stopMonitoring()
  }

  @Test("excluding a parent app also covers its helper processes")
  func exclusionCoversHelperProcesses() async {
    let harness = MonitorHarness()
    harness.settings.excludedBundleIDs = ["com.example.Dictation"]
    let monitor = harness.makeMonitor()

    monitor.startMonitoring(skipPermissionRequests: true)
    await settle()
    harness.activeCallers = ["com.example.Dictation.helper.renderer"]
    harness.clock.advance(by: .seconds(3))
    await settle()

    #expect(harness.recorderFactory.createdSessions.isEmpty)
    #expect(!monitor.isRecording)

    await monitor.stopMonitoring()
  }
}
