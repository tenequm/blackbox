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

    client.post(.startManualRecording)
    _ = try await client.waitUntil(description: "manual recording started") { snapshot in
      snapshot.isRecording && snapshot.isManualRecording
    }

    try client.playSystemAudioFixture()
    try? await Task.sleep(for: .seconds(4))

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
    #expect(duration > 2.5, "Expected non-trivial recording duration, got \(duration)s")

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
    // HFP renegotiation path — that's where the v0.7.x rate regression lived
    // (forcing the aggregate to 48kHz while HFP pinned 24kHz). Round-trip
    // A→B→A catches asymmetries where only one direction rebuilds cleanly.
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

    // Phase 2: A → B. Listener on kAudioHardwarePropertyDefaultOutputDevice
    // tears down the CATap + aggregate, rebuilds, resumes the IO proc.
    // D8 handles the silence gap.
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
    let ageCeilingMs: Double = hfpInvolved ? 8000 : 500
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

    // Belt-and-suspenders: confirm the listener actually fired.
    #expect(
      BlackboxLogProbe.containsAfter(
        "output device changed", since: logMarker),
      "Expected 'output device changed' log line after \(logMarker) - listener may not have fired"
    )

    if let maxSysAge = BlackboxLogProbe.maxSystemAgeAfter(since: logMarker) {
      #expect(
        maxSysAge < ageCeilingMs,
        "System audio stopped after device round-trip: sys_age=\(maxSysAge)ms (max \(ageCeilingMs)ms, hfp=\(hfpInvolved)). IO proc may have died."
      )
    } else {
      Issue.record("No drift logs found after \(logMarker) - cannot verify sys_age")
    }

    if let maxMicAge = BlackboxLogProbe.maxMicAgeAfter(since: logMarker) {
      #expect(
        maxMicAge < ageCeilingMs,
        "Mic stopped after output device round-trip: mic_age=\(maxMicAge)ms (max \(ageCeilingMs)ms, hfp=\(hfpInvolved)). AVAudioEngine may have stalled."
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
    let status: OSStatus
    let operation: String
    var description: String { "\(operation) failed: OSStatus=\(status)" }
  }

  static func listOutputDevices() throws -> [AudioDeviceID] {
    try allDevices().filter { hasStreams(deviceID: $0, scope: kAudioDevicePropertyScopeOutput) }
  }

  static func listInputDevices() throws -> [AudioDeviceID] {
    try allDevices().filter { hasStreams(deviceID: $0, scope: kAudioDevicePropertyScopeInput) }
  }

  static func defaultOutputDevice() throws -> AudioDeviceID {
    try defaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice)
  }

  static func defaultInputDevice() throws -> AudioDeviceID {
    try defaultDevice(selector: kAudioHardwarePropertyDefaultInputDevice)
  }

  static func setDefaultOutputDevice(_ id: AudioDeviceID) throws {
    try setDefaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice, deviceID: id)
  }

  static func setDefaultInputDevice(_ id: AudioDeviceID) throws {
    try setDefaultDevice(selector: kAudioHardwarePropertyDefaultInputDevice, deviceID: id)
  }

  static func deviceName(_ id: AudioDeviceID) -> String? {
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioObjectPropertyName,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name)
    guard status == noErr, let name else { return nil }
    return name.takeRetainedValue() as String
  }

  static func transportType(_ id: AudioDeviceID) -> UInt32 {
    var transport: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyTransportType,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport)
    return transport
  }

  static func isBuiltIn(_ id: AudioDeviceID) -> Bool {
    transportType(id) == kAudioDeviceTransportTypeBuiltIn
  }

  static func isBluetooth(_ id: AudioDeviceID) -> Bool {
    let t = transportType(id)
    return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
  }

  private static func allDevices() throws -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize)
    guard status == noErr else {
      throw DeviceError(status: status, operation: "GetPropertyDataSize(Devices)")
    }
    let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    status = ids.withUnsafeMutableBufferPointer { buffer -> OSStatus in
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize,
        buffer.baseAddress!)
    }
    guard status == noErr else {
      throw DeviceError(status: status, operation: "GetPropertyData(Devices)")
    }
    return ids
  }

  private static func hasStreams(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreams,
      mScope: scope,
      mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
    guard status == noErr else { return false }
    return dataSize > 0
  }

  private static func defaultDevice(selector: AudioObjectPropertySelector) throws -> AudioDeviceID {
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
    guard status == noErr else {
      throw DeviceError(status: status, operation: "GetPropertyData(DefaultDevice)")
    }
    return deviceID
  }

  private static func setDefaultDevice(
    selector: AudioObjectPropertySelector, deviceID: AudioDeviceID
  ) throws {
    var id = deviceID
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectSetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
      UInt32(MemoryLayout<AudioDeviceID>.size), &id)
    guard status == noErr else {
      throw DeviceError(status: status, operation: "SetPropertyData(DefaultDevice)")
    }
  }
}

// MARK: - Log file probe

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
    // before a listener fires can legitimately land in the same second as the
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
    let regex = try! NSRegularExpression(pattern: #"(\#(field))=(\d+\.?\d*)ms"#)

    while Date() < deadline {
      if let contents = try? String(contentsOf: logURL, encoding: .utf8) {
        var maxAge: Double?
        for line in contents.split(separator: "\n") where line.contains("drift:") {
          let head = line.prefix(20)
          let timestamp = String(head).replacingOccurrences(of: " ", with: "")
          guard let lineDate = formatter.date(from: timestamp), lineDate >= flooredSince else {
            continue
          }
          let lineStr = String(line)
          let range = NSRange(lineStr.startIndex..., in: lineStr)
          if let match = regex.firstMatch(in: lineStr, range: range),
            let valueRange = Range(match.range(at: 2), in: lineStr)
          {
            if let value = Double(lineStr[valueRange]) {
              maxAge = max(maxAge ?? 0, value)
            }
          }
        }
        if maxAge != nil { return maxAge }
      }
      Thread.sleep(forTimeInterval: 0.1)
    }
    return nil
  }

  /// Extracts the maximum sys_age (system audio staleness) from drift logs after `since`.
  /// A healthy sys_age is <100ms. If IO proc stops, sys_age grows unbounded.
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
