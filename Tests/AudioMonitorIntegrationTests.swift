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
    session.emitContinuityEvent(.outputDeviceChanged)
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
}
