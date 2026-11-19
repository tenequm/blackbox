import AVFoundation
import Testing

@testable import Blackbox

@Suite("Microphone speaker attribution")
struct MicActivityTests {
  private func fixture(
    in directory: URL, channels: [Int], systemSilent: Bool = false,
    systemFrames: AVAudioFrameCount = 192_000,
    micAmplitude: (Int) -> Float = { (48_000..<144_000).contains($0) ? 0.3 : 0 }
  ) async throws -> URL {
    let url = directory.appendingPathComponent(RecordingStore.audioName)
    let writer = try AVAssetWriter(url: url, fileType: .m4a)
    let inputs = channels.map { count in
      let input = AVAssetWriterInput(
        mediaType: .audio,
        outputSettings: [
          AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
          AVNumberOfChannelsKey: count, AVEncoderBitRateKey: count * 64000,
        ])
      writer.add(input)
      return input
    }
    try #require(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    for (index, input) in inputs.enumerated() {
      let format = try #require(
        AVAudioFormat(
          standardFormatWithSampleRate: 48000,
          channels: AVAudioChannelCount(channels[index])))
      let buffer = try #require(
        AVAudioPCMBuffer(pcmFormat: format, frameCapacity: index == 0 ? systemFrames : 192_000))
      buffer.frameLength = buffer.frameCapacity
      for channel in 0..<channels[index] {
        let data = try #require(buffer.floatChannelData)[channel]
        for sample in 0..<Int(buffer.frameLength) {
          let systemAmplitude: Float = !systemSilent && sample >= 96_000 ? 0.3 : 0
          let amplitude = index == 0 ? systemAmplitude : micAmplitude(sample)
          let value = sin(Float(sample) * 0.05) * amplitude
          data[sample] = channel == 0 ? value : -value
        }
      }
      let sample = try #require(buffer.asSampleBuffer(timestamp: AVAudioTime(hostTime: 0)))
      try #require(input.append(sample))
      input.markAsFinished()
    }
    await writer.finishWriting()
    try #require(writer.status == .completed, "\(String(describing: writer.error))")
    return url
  }

  @Test(arguments: [false, true])
  func gatesSpeechOnTheRecordedTimeline(systemSilent: Bool) async throws {
    let harness = try TranscriptionHarness()
    let url = try await fixture(in: harness.root, channels: [2, 1], systemSilent: systemSilent)
    let times: [(Double?, Double?)] = [
      (200, 600), (1200, 1600), (2200, 2600), (3200, 3600),
      (1500, 1500), (nil, 1400), (1600, 1300), (-1, 1500), (1400, nil),
    ]
    let tokens = times.map { TranscriptToken(text: "word", startMs: $0.0, endMs: $0.1, speaker: 2) }
    let result = try #require(await MicActivity.analyze(audio: url, tokens: tokens))
    #expect(result.localTokenIndices == (systemSilent ? [1, 2, 4] : [1, 4]))
    #expect(result.thresholds.systemThresholdDBFS == -105)
    #expect(result.thresholds.micThresholdDBFS == -50)
    #expect(!result.thresholds.usedAdaptiveMicThreshold)
  }

  @Test func bridgesBriefGapsBeforeDroppingShortMicRuns() async throws {
    let harness = try TranscriptionHarness()
    let url = try await fixture(in: harness.root, channels: [2, 1], systemSilent: true) { sample in
      let ms = sample / 48
      let burst =
        (700..<820).contains(ms) || (1020..<1140).contains(ms) || (2000..<2100).contains(ms)
      return burst ? 0.3 : 0.001
    }
    let tokens = [920.0, 2050.0, 3000.0].map {
      TranscriptToken(text: "voice", startMs: $0, endMs: $0, speaker: 2)
    }
    let result = try #require(await MicActivity.analyze(audio: url, tokens: tokens))
    #expect(result.thresholds.usedAdaptiveMicThreshold)
    #expect(result.thresholds.micThresholdDBFS > result.parameters.micFloorDBFS)
    #expect(result.localTokenIndices == [0])
  }

  @Test func missingSystemFramesFailTheGate() async throws {
    let harness = try TranscriptionHarness()
    let url = try await fixture(
      in: harness.root, channels: [2, 1], systemSilent: true, systemFrames: 96_000)
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    let system = try #require(tracks.first)
    let systemEnd = try await system.load(.timeRange).end.seconds
    try #require(abs(systemEnd - 2) < 0.02)
    let tokens = [1300.0, 2300.0].map {
      TranscriptToken(text: "voice", startMs: $0, endMs: $0 + 200, speaker: 1)
    }
    let result = try #require(await MicActivity.analyze(audio: url, tokens: tokens))
    #expect(result.localTokenIndices == [0])
  }

  @Test(arguments: [[1], [1, 1], [2, 1, 1], [1, 2]])
  func rejectsUnsupportedLayouts(channels: [Int]) async throws {
    let harness = try TranscriptionHarness()
    let url = try await fixture(in: harness.root, channels: channels)
    #expect(try await MicActivity.analyze(audio: url, tokens: []) == nil)
  }

  @Test func corruptCaptureFailsAnalysis() async throws {
    let harness = try TranscriptionHarness()
    let url = harness.root.appendingPathComponent(RecordingStore.audioName)
    try Data([0]).write(to: url)
    await #expect(throws: (any Error).self) {
      try await MicActivity.analyze(audio: url, tokens: [])
    }
  }

  @Test func projectionRestoresProviderLabelsAndNames() throws {
    let tokens = [(" Hello", 1), (" there", 2), (" remote", 2)].enumerated().map { index, word in
      TranscriptToken(
        text: word.0, startMs: Double(index * 100), endMs: Double(index * 100 + 90), speaker: word.1
      )
    }
    let document = TranscriptDocument(tokens: tokens, createdAt: Date())
    var sidecar = try #require(document.fetchedTokens)
    let originals = document.segments
    sidecar.attribution = SpeakerAttribution(
      version: 1, parameters: .init(),
      thresholds: .init(
        micThresholdDBFS: -50, usedAdaptiveMicThreshold: false, systemThresholdDBFS: -105),
      localTokenIndices: [0, 1], appliedAt: Date())
    let local = sidecar.project()
    #expect(local.map(\.text) == ["Hello there", "remote"])
    #expect(local.map(\.speaker) == [TranscriptSegment.localSpeaker, 2])
    let names = ["2": "Remote"]
    #expect(
      local.map { TranscriptSegment.speakerName(for: $0.speaker, names: names) } == [
        "You", "Remote",
      ])
    #expect(
      TranscriptSegment.speakerName(
        for: TranscriptSegment.localSpeaker,
        names: [String(TranscriptSegment.localSpeaker): "Local"]) == "Local")
    sidecar.attribution = nil
    #expect(sidecar.project().map(\.speaker) == [1, 2])
    #expect(sidecar.project().map(\.text) == ["Hello", "there remote"])
    #expect(sidecar.project().map(\.id) == originals.map(\.id))
    #expect(sidecar.tokens == tokens)
  }

  private enum Sidecar: CaseIterable { case legacy, malformedJSON, malformedTokens }

  @Test(arguments: Sidecar.allCases)
  private func readsAndRoundTripsSegmentsWithoutAttribution(sidecar: Sidecar) throws {
    let harness = try TranscriptionHarness()
    let file = TranscriptDocument.sidecarURL(for: harness.root)
    let json = #"{"segments":[{"speaker":2,"time":1,"text":"paid"}]}"#
    try Data(json.utf8).write(to: file)
    switch sidecar {
    case .legacy: break
    case .malformedJSON: try Data("{".utf8).write(to: TranscriptTokens.url(for: harness.root))
    case .malformedTokens:
      try Data(#"{"createdAt":0,"tokens":"bad"}"#.utf8).write(
        to: TranscriptTokens.url(for: harness.root))
    }
    let document = try #require(TranscriptDocument.load(for: harness.root))
    #expect(TranscriptTokens.load(for: harness.root) == nil)
    try document.save(for: harness.root)
    #expect(TranscriptDocument.load(for: harness.root)?.segments.first?.text == "paid")
  }
}
