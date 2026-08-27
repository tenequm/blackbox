import AVFoundation
import CoreAudio
import Foundation
import Testing

@testable import Blackbox

extension Tag {
  @Tag static var hardware: Self
}

@Suite("Hardware Smoke", .serialized)
struct HardwareSmokeTests {
  @Test(
    "manual recording through the app bundle produces a sane dual-track file",
    .tags(.hardware),
    .enabled(if: ProcessInfo.processInfo.environment["BLACKBOX_RUN_HARDWARE_SMOKE"] == "1"),
    .timeLimit(.minutes(1))
  )
  func manualRecordingProducesDualTrackFile() async throws {
    let client = try BlackboxSmokeClient()
    defer {
      client.terminate()
      try? FileManager.default.removeItem(at: client.saveDirectory)
    }

    try client.launch()

    _ = try await client.waitUntil(description: "app test channel ready") { snapshot in
      !snapshot.isRecording && !snapshot.isSaving
    }

    let logMarker = Date()
    client.post(.startManualRecording)
    let startedSnapshot = try await client.waitUntil(description: "manual recording started") {
      snapshot in
      snapshot.isRecording && snapshot.isManualRecording && snapshot.hudTitle != nil
    }
    #expect(startedSnapshot.hudTitle == HUDToast.startedTitle)
    #expect(startedSnapshot.hudSubtitle == "Manual recording")

    try client.playSystemAudioFixture()
    try? await Task.sleep(for: .seconds(4))

    let captureWindowEnd = Date()
    client.post(.stopManualRecording)
    let finalSnapshot = try await client.waitUntil(description: "recording saved") { snapshot in
      !snapshot.isRecording && !snapshot.isSaving && snapshot.lastSavedRecordingPath != nil
        && snapshot.hudTitle == HUDToast.savedTitle
    }
    #expect(finalSnapshot.hudSubtitle == "Manual recording")

    let recordingDir =
      try finalSnapshot.lastSavedRecordingPath.map(URL.init(fileURLWithPath:))
      ?? (try client.newestRecordingDirectory())
    let audioURL = recordingDir.appending(path: "audio.m4a")
    try #require(
      FileManager.default.fileExists(atPath: audioURL.path(percentEncoded: false)),
      "Expected audio.m4a at \(audioURL.path)")

    let asset = AVURLAsset(url: audioURL)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    #expect(tracks.count == 2, "Expected 2 audio tracks, found \(tracks.count)")

    let duration = try await asset.load(.duration).seconds
    #expect(duration > 2.5, "Expected non-trivial recording duration, got \(duration)s")

    // Regression guard for #17: a near-zero minimumFrameInterval makes SCStream
    // recomposite the display at refresh rate and drop every frame, because only
    // the audio output consumes samples. Each dropped frame costs a full-screen
    // recomposite in WindowServer.
    let droppedFrames = UnifiedLogProbe.droppedFrameCount(
      from: logMarker, to: captureWindowEnd)
    #expect(
      droppedFrames == 0,
      "SCStream dropped \(droppedFrames) video frames during capture - check minimumFrameInterval and the .screen output subscription"
    )

    var trackDurations: [Double] = []
    for track in tracks {
      let timeRange = try await track.load(.timeRange)
      trackDurations.append(timeRange.duration.seconds)
    }
    let minDuration = try #require(trackDurations.min())
    let maxDuration = try #require(trackDurations.max())
    #expect(maxDuration - minDuration < 0.02, "Track durations diverged: \(trackDurations)")
  }

  @Test(
    "recording survives default output device round-trip mid-capture",
    .tags(.hardware),
    .enabled(if: ProcessInfo.processInfo.environment["BLACKBOX_RUN_HARDWARE_SMOKE"] == "1"),
    .timeLimit(.minutes(2))
  )
  func outputDeviceSwitchDuringRecording() async throws {
    let outputs = try CoreAudioDevices.listOutputDevices()
    try #require(
      outputs.count >= 2,
      "Need at least 2 output devices for this test (found \(outputs.count)). Connect an external output (AirPods, USB, etc) and retry."
    )
    let originalOutput = try CoreAudioDevices.defaultOutputDevice()
    // Prefer a Bluetooth alternate when available so every run exercises the
    // HFP renegotiation path. Round-trip A→B→A catches asymmetries where only
    // one direction resumes cleanly.
    let alternateOutput = try #require(
      outputs.first(where: { $0 != originalOutput && CoreAudioDevices.isBluetooth($0) })
        ?? outputs.first(where: { $0 != originalOutput }),
      "No alternate output device available"
    )

    let originalName = CoreAudioDevices.deviceName(originalOutput) ?? "<unknown>"
    let alternateName = CoreAudioDevices.deviceName(alternateOutput) ?? "<unknown>"

    let client = try BlackboxSmokeClient()
    defer {
      try? CoreAudioDevices.setDefaultOutputDevice(originalOutput)
      client.terminate()
      try? FileManager.default.removeItem(at: client.saveDirectory)
    }

    try client.launch()
    _ = try await client.waitUntil(description: "app test channel ready") { snapshot in
      !snapshot.isRecording && !snapshot.isSaving
    }

    let logMarker = Date()

    client.post(.startManualRecording)
    _ = try await client.waitUntil(description: "manual recording started") { snapshot in
      snapshot.isRecording && snapshot.isManualRecording
    }

    // Phase 1: baseline on original device.
    try client.playSystemAudioFixture()
    try await Task.sleep(for: .seconds(2))

    // Phase 2: A → B. SCStream handles output-device changes transparently;
    // any transient silence is filled by D8.
    try CoreAudioDevices.setDefaultOutputDevice(alternateOutput)
    try await Task.sleep(for: .seconds(2))
    try client.playSystemAudioFixture()
    try await Task.sleep(for: .seconds(2))

    // Phase 3: B → A. Second rebuild in the opposite direction.
    try CoreAudioDevices.setDefaultOutputDevice(originalOutput)
    try await Task.sleep(for: .seconds(2))
    try client.playSystemAudioFixture()
    try await Task.sleep(for: .seconds(2))

    client.post(.stopManualRecording)
    let finalSnapshot = try await client.waitUntil(description: "recording saved") { snapshot in
      !snapshot.isRecording && !snapshot.isSaving && snapshot.lastSavedRecordingPath != nil
    }

    let recordingDir =
      try finalSnapshot.lastSavedRecordingPath.map(URL.init(fileURLWithPath:))
      ?? (try client.newestRecordingDirectory())
    let audioURL = recordingDir.appending(path: "audio.m4a")
    try #require(
      FileManager.default.fileExists(atPath: audioURL.path(percentEncoded: false)),
      "Expected audio.m4a at \(audioURL.path)")

    let asset = AVURLAsset(url: audioURL)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    #expect(tracks.count == 2, "Expected 2 audio tracks, found \(tracks.count)")

    let duration = try await asset.load(.duration).seconds
    #expect(duration > 9.0, "Expected ~12s recording across A→B→A, got \(duration)s")

    // HFP renegotiation can legitimately stall both streams for seconds while
    // macOS re-plumbs through CADefaultDeviceAggregate; loosen tolerances when
    // either endpoint is Bluetooth. The ceilings still catch truly dead IO
    // procs / stuck AVAudioEngine (those stall indefinitely).
    let hfpInvolved =
      CoreAudioDevices.isBluetooth(originalOutput)
      || CoreAudioDevices.isBluetooth(alternateOutput)
    // Non-HFP baselines, split by track:
    // - sys_age: SCStream is supposed to be transparent across default-output
    //   changes (its clock comes from the OS-composited mix, decoupled from
    //   any specific device). A healthy sys_age stays <100 ms; 500 ms catches
    //   real SCStream stalls tightly.
    // - mic_age: the AVAudioEngine reinstall gap on an output-device change
    //   is "sub-second" per spec D1 (up to ~1 s: HAL stall + 300 ms debounce
    //   + ~100 ms reinstall + first-buffer latency). The 5 s drift timer can
    //   land anywhere in that window; 1500 ms catches multi-second catastrophic
    //   stalls without false-failing on phase alignment.
    // HFP adds multi-second transport renegotiation on top; loosen both to 8 s.
    let sysAgeCeilingMs: Double = hfpInvolved ? 8000 : 500
    let micAgeCeilingMs: Double = hfpInvolved ? 8000 : 1500
    // Two rebuilds each add a D8 silence gap; HFP can add multi-second stalls.
    let divergenceCeilingS: Double = hfpInvolved ? 8.0 : 0.3

    var trackDurations: [Double] = []
    for track in tracks {
      let timeRange = try await track.load(.timeRange)
      trackDurations.append(timeRange.duration.seconds)
    }
    let minDuration = try #require(trackDurations.min())
    let maxDuration = try #require(trackDurations.max())
    #expect(
      maxDuration - minDuration < divergenceCeilingS,
      "Track durations diverged across output round-trip: \(trackDurations) (original=\(originalName), alternate=\(alternateName), hfp=\(hfpInvolved))"
    )

    // SCStream handles default-output changes transparently; there is no
    // explicit listener/log line to assert on. Track-duration divergence
    // (above) and the sys_age floor (below) are what matter.

    if let maxSysAge = BlackboxLogProbe.maxSystemAgeAfter(since: logMarker) {
      #expect(
        maxSysAge < sysAgeCeilingMs,
        "System audio stopped after device round-trip: sys_age=\(maxSysAge)ms (max \(sysAgeCeilingMs)ms, hfp=\(hfpInvolved)). SCStream audio may have stalled."
      )
    } else {
      Issue.record("No drift logs found after \(logMarker) - cannot verify sys_age")
    }

    if let maxMicAge = BlackboxLogProbe.maxMicAgeAfter(since: logMarker) {
      #expect(
        maxMicAge < micAgeCeilingMs,
        "Mic stopped after output device round-trip: mic_age=\(maxMicAge)ms (max \(micAgeCeilingMs)ms, hfp=\(hfpInvolved)). AVAudioEngine may have stalled."
      )
    } else {
      Issue.record("No drift logs found after \(logMarker) - cannot verify mic_age")
    }
  }

  @Test(
    "recording survives default input device switch mid-capture",
    .tags(.hardware),
    .enabled(if: ProcessInfo.processInfo.environment["BLACKBOX_RUN_HARDWARE_SMOKE"] == "1"),
    .timeLimit(.minutes(1))
  )
  func inputDeviceSwitchDuringRecording() async throws {
    let inputs = try CoreAudioDevices.listInputDevices()
    try #require(
      inputs.count >= 2,
      "Need at least 2 input devices for this test (found \(inputs.count)). Connect an external mic (AirPods, USB, etc) and retry."
    )
    let originalInput = try CoreAudioDevices.defaultInputDevice()
    let alternateInput = try #require(
      inputs.first { $0 != originalInput }, "No alternate input device available")

    let originalName = CoreAudioDevices.deviceName(originalInput) ?? "<unknown>"
    let alternateName = CoreAudioDevices.deviceName(alternateInput) ?? "<unknown>"

    let client = try BlackboxSmokeClient()
    defer {
      try? CoreAudioDevices.setDefaultInputDevice(originalInput)
      client.terminate()
      try? FileManager.default.removeItem(at: client.saveDirectory)
    }

    try client.launch()
    _ = try await client.waitUntil(description: "app test channel ready") { snapshot in
      !snapshot.isRecording && !snapshot.isSaving
    }

    let logMarker = Date()

    client.post(.startManualRecording)
    _ = try await client.waitUntil(description: "manual recording started") { snapshot in
      snapshot.isRecording && snapshot.isManualRecording
    }

    try client.playSystemAudioFixture()
    try await Task.sleep(for: .seconds(2))

    // Switch default input device mid-recording. AVAudioEngine will fire
    // AVAudioEngineConfigurationChange; the debounced handler tears down
    // the tap, re-queries D9 latency for the new device, and reinstalls.
    try CoreAudioDevices.setDefaultInputDevice(alternateInput)
    try await Task.sleep(for: .seconds(2))
    try client.playSystemAudioFixture()
    try await Task.sleep(for: .seconds(2))

    client.post(.stopManualRecording)
    let finalSnapshot = try await client.waitUntil(description: "recording saved") { snapshot in
      !snapshot.isRecording && !snapshot.isSaving && snapshot.lastSavedRecordingPath != nil
    }

    let recordingDir =
      try finalSnapshot.lastSavedRecordingPath.map(URL.init(fileURLWithPath:))
      ?? (try client.newestRecordingDirectory())
    let audioURL = recordingDir.appending(path: "audio.m4a")
    try #require(
      FileManager.default.fileExists(atPath: audioURL.path(percentEncoded: false)),
      "Expected audio.m4a at \(audioURL.path)")

    let asset = AVURLAsset(url: audioURL)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    #expect(tracks.count == 2, "Expected 2 audio tracks, found \(tracks.count)")

    let duration = try await asset.load(.duration).seconds
    #expect(duration > 4.0, "Expected ~6s recording across the switch, got \(duration)s")

    var trackDurations: [Double] = []
    for track in tracks {
      let timeRange = try await track.load(.timeRange)
      trackDurations.append(timeRange.duration.seconds)
    }
    let minDuration = try #require(trackDurations.min())
    let maxDuration = try #require(trackDurations.max())
    // Non-BT baseline: 300ms tolerance ≈ debounceConfigChange(300ms) + engine
    // restart jitter. Bluetooth inputs can legitimately stall multi-second
    // while HFP renegotiates; loosen accordingly.
    let hfpInvolved =
      CoreAudioDevices.isBluetooth(originalInput)
      || CoreAudioDevices.isBluetooth(alternateInput)
    let divergenceCeilingS: Double = hfpInvolved ? 8.0 : 0.3
    #expect(
      maxDuration - minDuration < divergenceCeilingS,
      "Track durations diverged across input switch: \(trackDurations) (original=\(originalName), alternate=\(alternateName), hfp=\(hfpInvolved))"
    )

    // Belt-and-suspenders: confirm the engine config-change path actually fired.
    #expect(
      BlackboxLogProbe.containsAfter(
        "audio engine config changed, restarting mic capture", since: logMarker),
      "Expected 'audio engine config changed' log line after \(logMarker) - handler may not have fired"
    )
  }
}

// MARK: - CoreAudio device helpers

enum CoreAudioDevices {
  struct DeviceError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
  }

  static func listOutputDevices() throws -> [AudioDeviceID] {
    try listDevices(direction: .output)
  }

  static func listInputDevices() throws -> [AudioDeviceID] {
    try listDevices(direction: .input)
  }

  static func defaultOutputDevice() throws -> AudioDeviceID {
    guard let device = try AudioHardwareSystem.shared.defaultOutputDevice else {
      throw DeviceError(message: "no default output device")
    }
    return device.id
  }

  static func defaultInputDevice() throws -> AudioDeviceID {
    guard let device = try AudioHardwareSystem.shared.defaultInputDevice else {
      throw DeviceError(message: "no default input device")
    }
    return device.id
  }

  static func setDefaultOutputDevice(_ id: AudioDeviceID) throws {
    try AudioHardwareSystem.shared.setDefaultOutputDevice(AudioHardwareDevice(id: id))
  }

  static func setDefaultInputDevice(_ id: AudioDeviceID) throws {
    try AudioHardwareSystem.shared.setDefaultInputDevice(AudioHardwareDevice(id: id))
  }

  static func deviceName(_ id: AudioDeviceID) -> String? {
    try? AudioHardwareDevice(id: id).name
  }

  static func transportType(_ id: AudioDeviceID) -> UInt32 {
    (try? AudioHardwareDevice(id: id).transportType) ?? 0
  }

  static func isBuiltIn(_ id: AudioDeviceID) -> Bool {
    transportType(id) == kAudioDeviceTransportTypeBuiltIn
  }

  static func isBluetooth(_ id: AudioDeviceID) -> Bool {
    let t = transportType(id)
    return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
  }

  private static func listDevices(direction: AudioHardwareDirection) throws -> [AudioDeviceID] {
    let devices = try AudioHardwareSystem.shared.devices
    return devices.compactMap { device in
      guard let streams = try? device.streams else { return nil }
      let hasMatchingStream = streams.contains { (try? $0.direction) == direction }
      return hasMatchingStream ? device.id : nil
    }
  }
}

// MARK: - Log file probe

extension HardwareSmokeTests {
  @Test(
    "idle app starts no capture and holds no screen-recording stream",
    .tags(.hardware),
    .enabled(if: ProcessInfo.processInfo.environment["BLACKBOX_RUN_HARDWARE_SMOKE"] == "1"),
    .timeLimit(.minutes(1))
  )
  func idleAppStartsNoCapture() async throws {
    let client = try BlackboxSmokeClient()
    defer {
      client.terminate()
      try? FileManager.default.removeItem(at: client.saveDirectory)
    }

    try client.launch()
    let snapshot = try await client.waitUntil(description: "app test channel ready") { snapshot in
      !snapshot.isRecording && !snapshot.isSaving
    }
    try #require(
      !snapshot.isRecording,
      "App auto-recorded at launch - quit any app holding mic + speaker (Zoom, Meet, Discord) and retry"
    )

    let logMarker = Date()
    try await Task.sleep(for: .seconds(20))
    let idleWindowEnd = Date()

    #expect(
      !BlackboxLogProbe.containsAfter("SCStream started", since: logMarker),
      "App started an SCStream while idle - a capture with no call in progress"
    )
    let droppedFrames = UnifiedLogProbe.droppedFrameCount(from: logMarker, to: idleWindowEnd)
    #expect(droppedFrames == 0, "Idle app produced \(droppedFrames) dropped video frames")

    let idleSnapshot = try await client.waitUntil(description: "still idle") { _ in true }
    #expect(!idleSnapshot.isRecording, "App began recording during the idle window")
  }
}

/// Reads the unified system log (`log show`) for entries ScreenCaptureKit emits
/// inside the Blackbox process. Our own file log cannot see these - they come
/// from the framework, not from `Log`.
enum UnifiedLogProbe {
  /// Counts "Dropping frame" entries attributed to Blackbox in a time window.
  /// Invokes `/usr/bin/log` by absolute path: a shell function or alias named
  /// `log` otherwise shadows it and silently yields an empty result.
  static func droppedFrameCount(from start: Date, to end: Date) -> Int {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    formatter.locale = Locale(identifier: "en_US_POSIX")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
    process.arguments = [
      "show",
      "--start", formatter.string(from: start.addingTimeInterval(-1)),
      "--end", formatter.string(from: end.addingTimeInterval(1)),
      "--predicate", #"process == "Blackbox" AND eventMessage CONTAINS "Dropping frame""#,
      "--style", "compact",
    ]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    guard (try? process.run()) != nil else { return 0 }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    let output = String(decoding: data, as: UTF8.self)
    return output.split(separator: "\n").count { $0.contains("Dropping frame") }
  }
}

enum BlackboxLogProbe {
  /// Polls `blackbox.log` for `pattern` on any line with a timestamp at or after
  /// `since`. Retries for `timeoutSeconds` because `LogFile.write` is async on a
  /// serial queue - a log call and its disk flush are not contemporaneous.
  /// Log lines start with an ISO-8601 timestamp: `YYYY-MM-DDTHH:MM:SSZ`.
  static func containsAfter(
    _ pattern: String, since: Date, timeoutSeconds: TimeInterval = 2.0
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    // Round `since` down to whole-second precision: the file logger writes
    // second-resolution timestamps, so a sub-second logMarker captured right
    // before an event fires can legitimately land in the same second as the
    // log line we are looking for.
    let flooredSince = Date(timeIntervalSince1970: floor(since.timeIntervalSince1970))
    let logURL = URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent("Library/Logs/Blackbox/blackbox.log")
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]

    while Date() < deadline {
      if let contents = try? String(contentsOf: logURL, encoding: .utf8) {
        for line in contents.split(separator: "\n") where line.contains(pattern) {
          let head = line.prefix(20)
          let timestamp = String(head).replacingOccurrences(of: " ", with: "")
          if let lineDate = formatter.date(from: timestamp), lineDate >= flooredSince {
            return true
          }
        }
      }
      Thread.sleep(forTimeInterval: 0.1)
    }
    return false
  }

  /// Parses a millisecond metric from a log line.
  ///
  /// Expected shape: `<field>=<value>ms` (e.g. `sys_age=3016.1ms`).
  /// Returns nil if the field is absent.
  ///
  /// If smoke tests start reporting "No drift logs found" unexpectedly,
  /// compare this format against `logDrift()` in `AudioRecorder.swift` -
  /// a rename (e.g. `sys_age_ms=`) silently breaks the regex.
  private static func parseMillis(from line: String, field: String) -> Double? {
    let pattern = #"(\#(field))=(\d+\.?\d*)ms"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(line.startIndex..., in: line)
    guard let match = regex.firstMatch(in: line, range: range),
      let valueRange = Range(match.range(at: 2), in: line)
    else { return nil }
    return Double(line[valueRange])
  }

  /// Extracts the maximum age for a drift-log field after `since`.
  /// Returns nil if no drift logs found. Drift logs look like:
  /// `drift: t=45.0s sys_age=3016.1ms mic_age=169.8ms ...`
  private static func maxAgeAfter(
    field: String,
    since: Date,
    timeoutSeconds: TimeInterval = 2.0
  ) -> Double? {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    let flooredSince = Date(timeIntervalSince1970: floor(since.timeIntervalSince1970))
    let logURL = URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent("Library/Logs/Blackbox/blackbox.log")
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]

    while Date() < deadline {
      if let contents = try? String(contentsOf: logURL, encoding: .utf8) {
        var maxAge: Double?
        for line in contents.split(separator: "\n") where line.contains("drift:") {
          let head = line.prefix(20)
          let timestamp = String(head).replacingOccurrences(of: " ", with: "")
          guard let lineDate = formatter.date(from: timestamp), lineDate >= flooredSince else {
            continue
          }
          if let value = parseMillis(from: String(line), field: field) {
            maxAge = max(maxAge ?? 0, value)
          }
        }
        if maxAge != nil { return maxAge }
      }
      Thread.sleep(forTimeInterval: 0.1)
    }
    return nil
  }

  /// Extracts the maximum sys_age (system audio staleness) from drift logs after `since`.
  /// A healthy sys_age is <100ms. If SCStream stalls, sys_age grows unbounded.
  static func maxSystemAgeAfter(since: Date, timeoutSeconds: TimeInterval = 2.0) -> Double? {
    maxAgeAfter(field: "sys_age", since: since, timeoutSeconds: timeoutSeconds)
  }

  /// Extracts the maximum mic_age (mic audio staleness) from drift logs after `since`.
  /// Healthy mic restarts may spike briefly during device churn; sustained growth means
  /// AVAudioEngine stopped delivering buffers.
  static func maxMicAgeAfter(since: Date, timeoutSeconds: TimeInterval = 2.0) -> Double? {
    maxAgeAfter(field: "mic_age", since: since, timeoutSeconds: timeoutSeconds)
  }
}
