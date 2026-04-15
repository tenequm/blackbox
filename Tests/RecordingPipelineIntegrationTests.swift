@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import Blackbox

@Suite("RecordingPipeline Integration")
struct RecordingPipelineIntegrationTests {
  private func makePipeline(
    micEnabled: Bool = true,
    alignmentMode: SessionAlignmentMode = .waitForAllTracks
  ) throws -> (RecordingPipeline, URL) {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "blackbox-pipeline-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let pipeline = RecordingPipeline(
      appName: "Pipeline Test",
      micEnabled: micEnabled,
      saveDirectory: root,
      alignmentMode: alignmentMode
    )
    return (pipeline, root)
  }

  private func makeSampleBuffer(
    startSample: Int64,
    sampleCount: Int = 1024,
    sampleRate: Double = RecordingPipeline.writerSampleRate
  ) -> CMSampleBuffer {
    RecordingPipeline.makeSilentSampleBuffer(
      channelCount: 1,
      sampleCount: sampleCount,
      sampleRate: sampleRate,
      presentationTimeStamp: CMTime(value: startSample, timescale: Int32(sampleRate))
    )!
  }

  /// Creates a mic sample buffer with PTS shifted backward by `offsetSamples` from
  /// the system-aligned position, simulating D9 latency compensation.
  private func makeMicBuffer(
    systemStartSample: Int64,
    offsetSamples: Int64,
    sampleCount: Int = 1024
  ) -> CMSampleBuffer {
    makeSampleBuffer(startSample: systemStartSample - offsetSamples, sampleCount: sampleCount)
  }

  private func trackDurations(for audioURL: URL) async throws -> [Double] {
    let asset = AVURLAsset(url: audioURL)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    var durations: [Double] = []
    for track in tracks {
      let timeRange = try await track.load(.timeRange)
      durations.append(timeRange.duration.seconds)
    }
    return durations
  }

  // MARK: - Core alignment & tail padding

  @Test("pads the shorter mic tail to the common end time")
  func padsShorterMicTail() async throws {
    let (pipeline, root) = try makePipeline()
    defer { try? FileManager.default.removeItem(at: root) }

    try pipeline.start()
    // sys@0 is dropped (session still pending), mic@0 anchors the session at pts=0,
    // sys@1024 arrives post-session and gets leading silence [0,1024].
    pipeline.appendSystemSample(makeSampleBuffer(startSample: 0))
    pipeline.appendMicSample(makeSampleBuffer(startSample: 0))
    pipeline.appendSystemSample(makeSampleBuffer(startSample: 1024))

    let outputDir = try #require(await pipeline.stop())
    let diagnostics = pipeline.currentDiagnostics
    let audioURL = outputDir.appending(path: "audio.m4a")
    let durations = try await trackDurations(for: audioURL)

    #expect(durations.count == 2)
    #expect(abs(durations[0] - durations[1]) < 0.05)
    #expect(diagnostics.micTailPaddingBuffers > 0)
    #expect(diagnostics.micTailPaddingSeconds > 0)
  }

  @Test("fills timeline gaps on the system track")
  func fillsSystemTrackGap() async throws {
    let (pipeline, root) = try makePipeline()
    defer { try? FileManager.default.removeItem(at: root) }

    try pipeline.start()
    // mic@0 queued (pending), sys@0 anchors session at 0, sys@4096 triggers gap fill.
    pipeline.appendMicSample(makeSampleBuffer(startSample: 0))
    pipeline.appendSystemSample(makeSampleBuffer(startSample: 0))
    pipeline.appendSystemSample(makeSampleBuffer(startSample: 4096))
    pipeline.appendMicSample(makeSampleBuffer(startSample: 1024))
    pipeline.appendMicSample(makeSampleBuffer(startSample: 2048))

    let outputDir = try #require(await pipeline.stop())
    let diagnostics = pipeline.currentDiagnostics
    let audioURL = outputDir.appending(path: "audio.m4a")
    let durations = try await trackDurations(for: audioURL)

    #expect(diagnostics.systemGapsFilled > 0)
    #expect(durations.count == 2)
    #expect(durations[0] > 0.08)
  }

  @Test("session start anchors on max(first_sys_pts, first_mic_pts)")
  func sessionStartAnchorsOnLaterTrack() async throws {
    let (pipeline, root) = try makePipeline()
    defer { try? FileManager.default.removeItem(at: root) }

    try pipeline.start()
    // mic PTS 2048, sys PTS 4096. Session start = max = 4096 on system.
    // The earlier mic sample is dropped before the session starts.
    pipeline.appendMicSample(makeSampleBuffer(startSample: 2048))
    pipeline.appendSystemSample(makeSampleBuffer(startSample: 4096))
    pipeline.appendMicSample(makeSampleBuffer(startSample: 4096))
    pipeline.appendMicSample(makeSampleBuffer(startSample: 5120))
    _ = await pipeline.stop()

    let diagnostics = pipeline.currentDiagnostics
    #expect(diagnostics.sessionStartTrack == .system)
    #expect(diagnostics.sessionStartPTS == CMTime(value: 4096, timescale: 48_000).seconds)
    #expect(diagnostics.micBuffersDroppedBeforeSession >= 1)
  }

  @Test("writes a single-track file when mic capture is disabled")
  func writesSingleTrackWithoutMic() async throws {
    let (pipeline, root) = try makePipeline(micEnabled: false)
    defer { try? FileManager.default.removeItem(at: root) }

    try pipeline.start()
    pipeline.appendSystemSample(makeSampleBuffer(startSample: 0))
    pipeline.appendSystemSample(makeSampleBuffer(startSample: 1024))

    let outputDir = try #require(await pipeline.stop())
    let asset = AVURLAsset(url: outputDir.appending(path: "audio.m4a"))
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    #expect(tracks.count == 1)
  }

  // MARK: - Deferred session start

  @Test("drops early-track samples arriving before the second track fires")
  func dropsEarlyTrackSamplesBeforeSessionStarts() async throws {
    let (pipeline, root) = try makePipeline()
    defer { try? FileManager.default.removeItem(at: root) }

    try pipeline.start()
    // System fires 4 times while mic is still booting. All four system samples
    // are dropped because session is still pending (waiting on mic).
    for i: Int64 in 0..<4 {
      pipeline.appendSystemSample(makeSampleBuffer(startSample: i * 1024))
    }
    // Mic finally arrives - session starts at max(first_sys=0, first_mic=5000)=5000.
    pipeline.appendMicSample(makeSampleBuffer(startSample: 5000))
    pipeline.appendMicSample(makeSampleBuffer(startSample: 6024))
    // A new system sample after session start is appended normally (with leading silence).
    pipeline.appendSystemSample(makeSampleBuffer(startSample: 6000))

    _ = await pipeline.stop()
    let diagnostics = pipeline.currentDiagnostics

    #expect(diagnostics.systemBuffersDroppedBeforeSession == 4)
    #expect(diagnostics.sessionStartTrack == .mic)
    #expect(diagnostics.sessionStartPTS == CMTime(value: 5000, timescale: 48_000).seconds)
    #expect(diagnostics.micBuffersAppended == 2)
    // sys@6000 is post-session, passes the sessionStart check (6000 > 5000) and appends
    // after filling leading silence from 5000 to 6000.
    #expect(diagnostics.systemBuffersAppended >= 1)
    #expect(diagnostics.systemLeadingSilenceBuffers >= 1)
  }

  @Test("session start times out when second track never fires")
  func sessionStartTimesOutWaitingForSecondTrack() async throws {
    let (pipeline, root) = try makePipeline()
    defer { try? FileManager.default.removeItem(at: root) }

    try pipeline.start()
    // System delivers samples spanning > 500ms of PTS with no mic. Timeout kicks in.
    // 500ms at 48kHz = 24000 samples. Feed 25 buffers of 1024 = 25600 samples.
    for i: Int64 in 0..<25 {
      pipeline.appendSystemSample(makeSampleBuffer(startSample: i * 1024))
    }
    // Add one more system sample after timeout - should be appended normally.
    pipeline.appendSystemSample(makeSampleBuffer(startSample: 25 * 1024))

    _ = await pipeline.stop()
    let diagnostics = pipeline.currentDiagnostics

    #expect(diagnostics.sessionStartTimedOut == true)
    #expect(diagnostics.sessionStartTrack == .system)
    #expect(diagnostics.sessionStartPTS == 0.0)
    // Before the timeout, the first N system samples are dropped while the code is
    // still waiting for mic. After the timeout, subsequent samples append normally.
    #expect(diagnostics.systemBuffersDroppedBeforeSession > 0)
    #expect(diagnostics.systemBuffersAppended > 0)
  }

  @Test("leading silence fills when late mic arrives after timeout")
  func leadingSilenceFillsAfterTimeout() async throws {
    let (pipeline, root) = try makePipeline()
    defer { try? FileManager.default.removeItem(at: root) }

    try pipeline.start()
    // Feed enough system samples to trigger the 500ms sample-time timeout.
    for i: Int64 in 0..<25 {
      pipeline.appendSystemSample(makeSampleBuffer(startSample: i * 1024))
    }
    // Mic finally arrives, way past the session start. Leading silence should fill.
    pipeline.appendMicSample(makeSampleBuffer(startSample: 30 * 1024))
    pipeline.appendMicSample(makeSampleBuffer(startSample: 31 * 1024))

    let outputDir = try #require(await pipeline.stop())
    let diagnostics = pipeline.currentDiagnostics
    let durations = try await trackDurations(for: outputDir.appending(path: "audio.m4a"))

    #expect(durations.count == 2)
    #expect(diagnostics.sessionStartTimedOut == true)
    #expect(diagnostics.micLeadingSilenceBuffers > 0)
    #expect(diagnostics.micLeadingSilenceSeconds > 0.5)  // 30*1024/48000 = ~640ms
  }

  @Test("tail padding closes gaps with partial final chunk")
  func tailPaddingClosesGapsWithPartialFinalChunk() async throws {
    let (pipeline, root) = try makePipeline()
    defer { try? FileManager.default.removeItem(at: root) }

    try pipeline.start()
    // sys@0 (pending, dropped) → mic@0 anchors session at 0 on mic.
    // Subsequent sys samples arrive post-session with leading silence [0,1024] then real.
    // Total sys = 4596 samples (4 full + 1 partial of 500).
    // Mic stops at [0, 1024]. Tail gap on mic = 3572 samples = 3 full + 1 partial (500).
    pipeline.appendSystemSample(makeSampleBuffer(startSample: 0))
    pipeline.appendMicSample(makeSampleBuffer(startSample: 0))
    pipeline.appendSystemSample(makeSampleBuffer(startSample: 1024))
    pipeline.appendSystemSample(makeSampleBuffer(startSample: 2048))
    pipeline.appendSystemSample(makeSampleBuffer(startSample: 3072))
    pipeline.appendSystemSample(makeSampleBuffer(startSample: 4096, sampleCount: 500))

    let outputDir = try #require(await pipeline.stop())
    let diagnostics = pipeline.currentDiagnostics
    let durations = try await trackDurations(for: outputDir.appending(path: "audio.m4a"))

    #expect(durations.count == 2)
    #expect(abs(durations[0] - durations[1]) < 0.005)
    // 3 full 1024-sample chunks + 1 partial 500-sample chunk = 4 buffers
    #expect(diagnostics.micTailPaddingBuffers == 4)
  }

  // MARK: - D9 Latency Offset

  @Test("constant D9 offset: early mic samples dropped, rest aligned")
  func constantD9OffsetProducesBothTracks() async throws {
    let (pipeline, root) = try makePipeline()
    defer { try? FileManager.default.removeItem(at: root) }

    let base: Int64 = 48_000
    let offset: Int64 = 2_400  // 50ms at 48kHz

    try pipeline.start()

    // Feed the initial pair. Mic fires first (D9-adjusted PTS is earlier),
    // but session anchors at max = sys PTS. First mic sample is dropped.
    pipeline.appendMicSample(makeMicBuffer(systemStartSample: base, offsetSamples: offset))
    pipeline.appendSystemSample(makeSampleBuffer(startSample: base))

    for i: Int64 in 1..<10 {
      let sysPTS = base + i * 1024
      pipeline.appendMicSample(makeMicBuffer(systemStartSample: sysPTS, offsetSamples: offset))
      pipeline.appendSystemSample(makeSampleBuffer(startSample: sysPTS))
    }

    let outputDir = try #require(await pipeline.stop())
    let diagnostics = pipeline.currentDiagnostics
    let durations = try await trackDurations(for: outputDir.appending(path: "audio.m4a"))

    #expect(durations.count == 2)
    #expect(abs(durations[0] - durations[1]) < 0.1)
    #expect(diagnostics.sessionStartTrack == .system)
    #expect(diagnostics.systemBuffersAppended == 10)
    // Mic samples with pts < sessionStart are dropped. The rest append.
    #expect(diagnostics.micBuffersDroppedBeforeSession >= 3)
    #expect(diagnostics.micBuffersAppended >= 6)
  }

  @Test("D9 offset decrease mid-recording triggers mic gap fill")
  func d9OffsetDecreaseTriggersGapFill() async throws {
    let (pipeline, root) = try makePipeline()
    defer { try? FileManager.default.removeItem(at: root) }

    let base: Int64 = 48_000
    let highOffset: Int64 = 2_400  // 50ms
    let lowOffset: Int64 = 960  // 20ms

    try pipeline.start()

    // First 5 buffers with high-latency device offset (session anchors on sys)
    pipeline.appendMicSample(makeMicBuffer(systemStartSample: base, offsetSamples: highOffset))
    pipeline.appendSystemSample(makeSampleBuffer(startSample: base))
    for i: Int64 in 1..<5 {
      let sysPTS = base + i * 1024
      pipeline.appendMicSample(makeMicBuffer(systemStartSample: sysPTS, offsetSamples: highOffset))
      pipeline.appendSystemSample(makeSampleBuffer(startSample: sysPTS))
    }

    // Next 5 buffers with low-latency device offset (30ms forward jump on mic)
    for i: Int64 in 5..<10 {
      let sysPTS = base + i * 1024
      pipeline.appendMicSample(makeMicBuffer(systemStartSample: sysPTS, offsetSamples: lowOffset))
      pipeline.appendSystemSample(makeSampleBuffer(startSample: sysPTS))
    }

    let outputDir = try #require(await pipeline.stop())
    let diagnostics = pipeline.currentDiagnostics
    let durations = try await trackDurations(for: outputDir.appending(path: "audio.m4a"))

    #expect(durations.count == 2)
    #expect(abs(durations[0] - durations[1]) < 0.1)
    // Mid-recording gap fills should exceed tail padding (offset change caused a real gap)
    #expect(diagnostics.micGapsFilled > diagnostics.micTailPaddingBuffers)
    #expect(diagnostics.systemGapsFilled == 0)
  }

  @Test("D9 offset increase mid-recording preserves valid output")
  func d9OffsetIncreasePreservesOutput() async throws {
    let (pipeline, root) = try makePipeline()
    defer { try? FileManager.default.removeItem(at: root) }

    let base: Int64 = 48_000
    let lowOffset: Int64 = 960  // 20ms
    let highOffset: Int64 = 2_400  // 50ms

    try pipeline.start()

    // First 5 buffers with low-latency device offset
    pipeline.appendMicSample(makeMicBuffer(systemStartSample: base, offsetSamples: lowOffset))
    pipeline.appendSystemSample(makeSampleBuffer(startSample: base))
    for i: Int64 in 1..<5 {
      let sysPTS = base + i * 1024
      pipeline.appendMicSample(makeMicBuffer(systemStartSample: sysPTS, offsetSamples: lowOffset))
      pipeline.appendSystemSample(makeSampleBuffer(startSample: sysPTS))
    }

    // Next 5 buffers with high-latency device offset (30ms backward PTS shift on mic)
    for i: Int64 in 5..<10 {
      let sysPTS = base + i * 1024
      pipeline.appendMicSample(makeMicBuffer(systemStartSample: sysPTS, offsetSamples: highOffset))
      pipeline.appendSystemSample(makeSampleBuffer(startSample: sysPTS))
    }

    let outputDir = try #require(await pipeline.stop())
    let diagnostics = pipeline.currentDiagnostics
    let durations = try await trackDurations(for: outputDir.appending(path: "audio.m4a"))

    #expect(durations.count == 2)
    #expect(abs(durations[0] - durations[1]) < 0.15)
    #expect(diagnostics.micBuffersAppendFailed <= 1)
    // Under the new delayed-session rule, the first D9-shifted mic sample (PTS < sys base)
    // is dropped before session starts.
    #expect(diagnostics.micBuffersDroppedBeforeSession >= 1)
  }

  // MARK: - preserveAllContent mode (manual recordings)

  @Test("preserveAllContent: session starts immediately on first sample")
  func preserveAllContentStartsOnFirstSample() async throws {
    let (pipeline, root) = try makePipeline(alignmentMode: .preserveAllContent)
    defer { try? FileManager.default.removeItem(at: root) }

    try pipeline.start()
    // System fires first; session starts immediately at pts=0 on system.
    pipeline.appendSystemSample(makeSampleBuffer(startSample: 0))
    pipeline.appendSystemSample(makeSampleBuffer(startSample: 1024))
    pipeline.appendSystemSample(makeSampleBuffer(startSample: 2048))
    // Mic arrives late; leading silence fills [0, 2112], real samples append from there.
    pipeline.appendMicSample(makeSampleBuffer(startSample: 2112))
    pipeline.appendMicSample(makeSampleBuffer(startSample: 2112 + 1024))

    let outputDir = try #require(await pipeline.stop())
    let diagnostics = pipeline.currentDiagnostics
    let durations = try await trackDurations(for: outputDir.appending(path: "audio.m4a"))

    #expect(durations.count == 2)
    #expect(abs(durations[0] - durations[1]) < 0.01)
    #expect(diagnostics.sessionStartTrack == .system)
    #expect(diagnostics.sessionStartPTS == 0.0)
    // No pre-session drops in this mode - every captured sample is preserved.
    #expect(diagnostics.systemBuffersDroppedBeforeSession == 0)
    #expect(diagnostics.micBuffersDroppedBeforeSession == 0)
    #expect(diagnostics.systemBuffersAppended == 3)
    #expect(diagnostics.micBuffersAppended == 2)
    // Late mic gets leading silence.
    #expect(diagnostics.micLeadingSilenceBuffers > 0)
    #expect(abs(diagnostics.micLeadingSilenceSeconds - (2112.0 / 48_000.0)) < 0.001)
  }

  @Test("preserveAllContent: short recording with only one track still produces output")
  func preserveAllContentShortSingleTrackRecording() async throws {
    let (pipeline, root) = try makePipeline(alignmentMode: .preserveAllContent)
    defer { try? FileManager.default.removeItem(at: root) }

    try pipeline.start()
    // Only system fires, mic never starts. User stops immediately.
    // Under preserveAllContent, session starts on the first sample, so we get output.
    pipeline.appendSystemSample(makeSampleBuffer(startSample: 0))
    pipeline.appendSystemSample(makeSampleBuffer(startSample: 1024))

    let outputDir = try #require(await pipeline.stop())
    let diagnostics = pipeline.currentDiagnostics
    let audioURL = outputDir.appending(path: "audio.m4a")
    #expect(FileManager.default.fileExists(atPath: audioURL.path(percentEncoded: false)))

    let asset = AVURLAsset(url: audioURL)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    // The key guarantee: output exists and has system content. AVAssetWriter may
    // finalize with 1 track (system only, since mic input was never appended to)
    // or 2 tracks (system + empty mic); either is acceptable.
    #expect(tracks.count >= 1)
    #expect(diagnostics.sessionStartTrack == .system)
    #expect(diagnostics.systemBuffersAppended == 2)
    #expect(diagnostics.micBuffersAppended == 0)
  }

  @Test("preserveAllContent: mic-first session then late system gets leading silence")
  func preserveAllContentMicFirstLateSystem() async throws {
    let (pipeline, root) = try makePipeline(alignmentMode: .preserveAllContent)
    defer { try? FileManager.default.removeItem(at: root) }

    try pipeline.start()
    // Mic fires first; session starts at pts=0 on mic.
    pipeline.appendMicSample(makeSampleBuffer(startSample: 0))
    pipeline.appendMicSample(makeSampleBuffer(startSample: 1024))
    pipeline.appendMicSample(makeSampleBuffer(startSample: 2048))
    // System arrives late; leading silence on system, then real samples.
    pipeline.appendSystemSample(makeSampleBuffer(startSample: 1500))
    pipeline.appendSystemSample(makeSampleBuffer(startSample: 1500 + 1024))

    let outputDir = try #require(await pipeline.stop())
    let diagnostics = pipeline.currentDiagnostics
    let durations = try await trackDurations(for: outputDir.appending(path: "audio.m4a"))

    #expect(durations.count == 2)
    #expect(abs(durations[0] - durations[1]) < 0.01)
    #expect(diagnostics.sessionStartTrack == .mic)
    #expect(diagnostics.sessionStartPTS == 0.0)
    #expect(diagnostics.systemLeadingSilenceBuffers > 0)
    #expect(abs(diagnostics.systemLeadingSilenceSeconds - (1500.0 / 48_000.0)) < 0.001)
    #expect(diagnostics.micLeadingSilenceBuffers == 0)
    // All samples preserved - no drops.
    #expect(diagnostics.systemBuffersDroppedBeforeSession == 0)
    #expect(diagnostics.micBuffersDroppedBeforeSession == 0)
  }
}
