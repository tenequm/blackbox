import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

@Observable
final class AudioMonitor {
  private(set) var isRecording = false
  private(set) var currentAppName: String?
  private(set) var recordingStartTime: Date?
  private(set) var permissionNeeded = false
  private(set) var isManualRecording = false

  private var sessions: [String: RecordingSession] = [:]
  private var monitoringTask: Task<Void, Never>?
  private var notificationTokens: [NSObjectProtocol] = []

  // Tracks when each app last had a meeting window visible
  private var meetingLastSeen: [String: Date] = [:]

  // Manual recording state
  private var manualRecorder: AudioRecorder?

  var targetBundleIDs: Set<String> = []
  var meetingPatterns: [String] = []
  var gracePeriod: TimeInterval = 30
  var micEnabled: Bool = true
  var saveDirectory: URL = URL(fileURLWithPath: defaultSaveDirectoryPath)

  func startMonitoring() {
    guard monitoringTask == nil else { return }
    loadSettings()

    // Check screen recording permission
    if !CGPreflightScreenCaptureAccess() {
      permissionNeeded = true
    }

    let ws = NSWorkspace.shared.notificationCenter
    notificationTokens.append(
      ws.addObserver(
        forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
      ) {
        [weak self] _ in
        MainActor.assumeIsolated { self?.pollMeetingWindows() }
      }
    )
    notificationTokens.append(
      ws.addObserver(
        forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
      ) {
        [weak self] notification in
        let bundleID =
          (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
          .bundleIdentifier
        MainActor.assumeIsolated {
          guard let self, let bundleID else { return }
          self.meetingLastSeen.removeValue(forKey: bundleID)
          self.stopSession(bundleID: bundleID)
        }
      }
    )

    monitoringTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        self.loadSettings()
        self.pollMeetingWindows()
        try? await Task.sleep(for: .seconds(3))
      }
    }
  }

  /// Stops all monitoring and recording. Async to ensure files are finalized.
  func stopMonitoring() async {
    monitoringTask?.cancel()
    monitoringTask = nil
    for token in notificationTokens {
      NSWorkspace.shared.notificationCenter.removeObserver(token)
    }
    notificationTokens.removeAll()

    for (_, session) in sessions {
      await session.recorder.stop()
    }
    sessions.removeAll()

    if let recorder = manualRecorder {
      await recorder.stop()
      manualRecorder = nil
      isManualRecording = false
    }
    updateState()
  }

  // MARK: - Manual Recording

  func startManualRecording(bundleID: String) {
    guard manualRecorder == nil else { return }

    let runningApps = NSWorkspace.shared.runningApplications
    let appName =
      runningApps.first(where: { $0.bundleIdentifier == bundleID })?
      .localizedName ?? bundleID.components(separatedBy: ".").last ?? bundleID

    let recorder = AudioRecorder(
      bundleID: bundleID,
      appName: appName,
      micEnabled: micEnabled,
      saveDirectory: saveDirectory
    )

    recorder.onError = { [weak self] error in
      Task { @MainActor [weak self] in
        print("Blackbox: manual recording error: \(error)")
        self?.manualRecorder = nil
        self?.isManualRecording = false
        self?.updateState()
      }
    }

    manualRecorder = recorder
    isManualRecording = true
    recordingStartTime = Date()
    currentAppName = appName
    isRecording = true

    Task {
      do {
        try await recorder.start()
      } catch {
        print("Blackbox: failed to start manual recording: \(error)")
        manualRecorder = nil
        isManualRecording = false
        updateState()
      }
    }
  }

  func stopManualRecording() {
    guard let recorder = manualRecorder else { return }
    manualRecorder = nil
    isManualRecording = false
    Task {
      await recorder.stop()
      updateState()
    }
  }

  // MARK: - Meeting Window Detection

  private func pollMeetingWindows() {
    // Re-check permission each cycle
    if !CGPreflightScreenCaptureAccess() {
      permissionNeeded = true
      return
    }
    permissionNeeded = false

    let runningApps = NSWorkspace.shared.runningApplications
    let windowList =
      CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]] ?? []

    // Stop sessions for apps removed from target list
    for bundleID in sessions.keys where !targetBundleIDs.contains(bundleID) {
      stopSession(bundleID: bundleID)
    }

    for bundleID in targetBundleIDs {
      guard let app = runningApps.first(where: { $0.bundleIdentifier == bundleID }) else {
        if sessions[bundleID] != nil {
          stopSession(bundleID: bundleID)
          meetingLastSeen.removeValue(forKey: bundleID)
        }
        continue
      }

      let hasMeeting = windowList.contains { window in
        guard let pid = window[kCGWindowOwnerPID as String] as? Int32,
          pid == app.processIdentifier,
          let title = window[kCGWindowName as String] as? String,
          !title.isEmpty
        else { return false }
        return meetingPatterns.contains { title.localizedCaseInsensitiveContains($0) }
      }

      if hasMeeting {
        meetingLastSeen[bundleID] = Date()
        if sessions[bundleID] == nil {
          let appName = app.localizedName ?? bundleID.components(separatedBy: ".").last ?? bundleID
          startSession(bundleID: bundleID, appName: appName)
        }
      } else if sessions[bundleID] != nil {
        let lastSeen = meetingLastSeen[bundleID] ?? Date.distantPast
        if Date().timeIntervalSince(lastSeen) >= gracePeriod {
          stopSession(bundleID: bundleID)
          meetingLastSeen.removeValue(forKey: bundleID)
        }
      }
    }
  }

  // MARK: - Session Management

  private func startSession(bundleID: String, appName: String) {
    let recorder = AudioRecorder(
      bundleID: bundleID,
      appName: appName,
      micEnabled: micEnabled,
      saveDirectory: saveDirectory
    )

    sessions[bundleID] = RecordingSession(
      bundleID: bundleID,
      appName: appName,
      recorder: recorder,
      startTime: Date()
    )

    recorder.onError = { [weak self] error in
      Task { @MainActor [weak self] in
        print("Blackbox: stream error for \(appName): \(error)")
        self?.stopSession(bundleID: bundleID)
      }
    }

    Task {
      do {
        try await recorder.start()
        updateState()
      } catch {
        print("Blackbox: failed to start recording \(appName): \(error)")
        if let scError = error as? SCStreamError, scError.code == .userDeclined {
          permissionNeeded = true
        }
        sessions.removeValue(forKey: bundleID)
        updateState()
      }
    }
  }

  private func stopSession(bundleID: String) {
    guard let session = sessions.removeValue(forKey: bundleID) else { return }
    Task {
      await session.recorder.stop()
      updateState()
    }
  }

  private func updateState() {
    guard !isManualRecording else { return }
    // Pick the earliest-started session for display (deterministic)
    let active = sessions.values.min(by: { $0.startTime < $1.startTime })
    isRecording = active != nil
    currentAppName = active.map {
      sessions.count > 1 ? "\($0.appName) +\(sessions.count - 1)" : $0.appName
    }
    recordingStartTime = active?.startTime
  }

  private func loadSettings() {
    let defaults = UserDefaults.standard

    let raw = defaults.string(forKey: "targetBundleIDs") ?? defaultTargetBundleIDsJSON
    if let data = raw.data(using: .utf8),
      let ids = try? JSONDecoder().decode([String].self, from: data)
    {
      targetBundleIDs = Set(ids)
    }

    let patternsRaw = defaults.string(forKey: "meetingPatterns") ?? defaultMeetingPatternsJSON
    if let data = patternsRaw.data(using: .utf8),
      let patterns = try? JSONDecoder().decode([String].self, from: data)
    {
      meetingPatterns = patterns
    }

    gracePeriod = defaults.double(forKey: "gracePeriod").clamped(to: 5...60, default: 30)
    micEnabled = defaults.object(forKey: "micEnabled") as? Bool ?? true
    let path = defaults.string(forKey: "saveDirectoryPath") ?? defaultSaveDirectoryPath
    saveDirectory = URL(fileURLWithPath: path)
  }
}

private struct RecordingSession {
  let bundleID: String
  let appName: String
  let recorder: AudioRecorder
  let startTime: Date
}

extension Double {
  fileprivate func clamped(to range: ClosedRange<Double>, default defaultValue: Double) -> Double {
    self == 0 ? defaultValue : min(max(self, range.lowerBound), range.upperBound)
  }
}
