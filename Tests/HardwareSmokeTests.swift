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
    "recording survives default output device switch mid-capture",
    .tags(.hardware),
    .enabled(if: ProcessInfo.processInfo.environment["BLACKBOX_RUN_HARDWARE_SMOKE"] == "1"),
    .timeLimit(.minutes(1))
  )
  func outputDeviceSwitchDuringRecording() async throws {
    let outputs = try CoreAudioDevices.listOutputDevices()
    try #require(
      outputs.count >= 2,
      "Need at least 2 output devices for this test (found \(outputs.count)). Connect an external output (AirPods, USB, etc) and retry."
    )
    let originalOutput = try CoreAudioDevices.defaultOutputDevice()
    let alternateOutput = try #require(
      outputs.first { $0 != originalOutput }, "No alternate output device available")

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

    try client.playSystemAudioFixture()
    try await Task.sleep(for: .seconds(2))

    // Switch default output device mid-recording. The app's listener on
    // kAudioHardwarePropertyDefaultOutputDevice should fire, tear down the
    // CATap + aggregate device, rebuild, and resume the IO proc. D8 handles
    // the silence gap during rebuild.
    try CoreAudioDevices.setDefaultOutputDevice(alternateOutput)
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
    // Wider tolerance than the baseline: D8 silence gap during aggregate rebuild
    // can legitimately add 50-150ms of divergence.
    #expect(
      maxDuration - minDuration < 0.15,
      "Track durations diverged across output switch: \(trackDurations) (original=\(originalName), alternate=\(alternateName))"
    )

    // Belt-and-suspenders: confirm the listener actually fired.
    #expect(
      BlackboxLogProbe.containsAfter(
        "output device changed, rebuilding aggregate device", since: logMarker),
      "Expected 'output device changed' log line after \(logMarker) - listener may not have fired"
    )
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
    // Mic tap reinstall can introduce a gap while AVAudioEngine restarts.
    // 300ms tolerance = debounceConfigChange(300ms) in AudioRecorder.swift's
    // debounceConfigChange + engine restart jitter. If that debounce value
    // changes, update this tolerance accordingly.
    #expect(
      maxDuration - minDuration < 0.3,
      "Track durations diverged across input switch: \(trackDurations) (original=\(originalName), alternate=\(alternateName))"
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
}
