@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import Blackbox

@Suite("Mic Attribution")
struct MicAttributionTests {

  // MARK: Rule on synthetic energies

  /// 20 ms frames: `silence` dBFS everywhere except the given second ranges.
  private func energies(
    seconds: Double, mic: [ClosedRange<Double>], system: [ClosedRange<Double>],
    speech: Double = -20, silence: Double = -90
  ) -> MicAttribution.TrackEnergies {
    let count = Int(seconds * 50)
    func track(_ ranges: [ClosedRange<Double>]) -> [Double] {
      (0..<count).map { frame in
        let t = Double(frame) / 50
        return ranges.contains { $0.contains(t) } ? speech : silence
      }
    }
    return MicAttribution.TrackEnergies(mic: track(mic), system: track(system))
  }

  private func token(at seconds: Double, speaker: Int = 2) -> TranscriptToken {
    TranscriptToken(
      text: " w", startMs: seconds * 1000, endMs: seconds * 1000 + 60, speaker: speaker)
  }

  private func localIndices(_ outcome: MicAttribution.Outcome) -> Set<Int>? {
    guard case .attributed(let indices, _, _) = outcome else { return nil }
    return indices
  }

  @Test("mic-only speech is local; system-only and double-talk keep their label")
  func gatesOnSystemQuiet() throws {
    let tracks = energies(seconds: 10, mic: [1...2, 5...6], system: [3...4, 5...6])
    let tokens = [token(at: 1.5), token(at: 3.5), token(at: 5.5), token(at: 8)]
    let outcome = MicAttribution.attribute(tokens: tokens, energies: tracks)
    #expect(try #require(localIndices(outcome)) == [0])
  }

  @Test("echo - the same audio on both tracks at once - is never local")
  func rejectsEcho() throws {
    let tracks = energies(seconds: 6, mic: [1...4], system: [1...4])
    let outcome = MicAttribution.attribute(
      tokens: [token(at: 1.5), token(at: 3)], energies: tracks)
    #expect(try #require(localIndices(outcome)).isEmpty)
  }

  @Test("a frame with no system audio fails the gate rather than reading as quiet")
  func unknownSystemIsNotQuiet() throws {
    var tracks = energies(seconds: 6, mic: [1...4], system: [])
    for frame in 50..<100 { tracks.system[frame] = .nan }
    let outcome = MicAttribution.attribute(
      tokens: [token(at: 1.5, speaker: 1), token(at: 3, speaker: 2)], energies: tracks)
    #expect(try #require(localIndices(outcome)) == [1])
  }

  @Test("a speaker that is only the user becomes You whole, pauses included")
  func promotesEntirelyLocalSpeaker() throws {
    let tracks = energies(seconds: 10, mic: [1...2, 4...5], system: [7...9])
    // Speaker 1 talks in both mic bursts and once in the silence between them;
    // speaker 2 is the remote voice.
    let tokens = [
      token(at: 1.5, speaker: 1), token(at: 3, speaker: 1), token(at: 4.5, speaker: 1),
      token(at: 8, speaker: 2),
    ]
    let outcome = MicAttribution.attribute(tokens: tokens, energies: tracks)
    #expect(try #require(localIndices(outcome)) == [0, 1, 2])
  }

  @Test("a speaker merged with a remote voice is gated word by word, not promoted")
  func doesNotPromoteMergedSpeaker() throws {
    let tracks = energies(seconds: 10, mic: [1...2], system: [4...8])
    let tokens = [
      token(at: 1.5), token(at: 1.8), token(at: 3), token(at: 5), token(at: 6), token(at: 7),
    ]
    let outcome = MicAttribution.attribute(tokens: tokens, energies: tracks)
    #expect(try #require(localIndices(outcome)) == [0, 1])
  }

  @Test("a promoted speaker's clearly remote tokens keep their label")
  func promotedSpeakerKeepsRemoteTokens() throws {
    let tracks = energies(seconds: 30, mic: [1...20], system: [25...26])
    var tokens = (0..<19).map { token(at: 1.5 + Double($0), speaker: 1) }
    tokens.append(token(at: 25.5, speaker: 1))
    let outcome = MicAttribution.attribute(tokens: tokens, energies: tracks)
    #expect(try #require(localIndices(outcome)) == Set(0..<19))
  }

  @Test("digital silence on the system track keeps the gate finite")
  func digitalSilenceSystem() throws {
    let tracks = energies(seconds: 4, mic: [1...2], system: [], silence: -120)
    let outcome = MicAttribution.attribute(tokens: [token(at: 1.5)], energies: tracks)
    guard case .attributed(let indices, _, let quietBelow) = outcome else {
      Issue.record("expected attribution, got \(outcome)")
      return
    }
    #expect(quietBelow.isFinite)
    #expect(indices == [0])
  }

  @Test("an empty mic track is ineligible, not an empty attribution")
  func emptyMicIsIneligible() {
    var tracks = energies(seconds: 2, mic: [], system: [])
    tracks.mic = tracks.mic.map { _ in .nan }
    if case .attributed = MicAttribution.attribute(tokens: [token(at: 1)], energies: tracks) {
      Issue.record("expected ineligible")
    }
  }

  @Test("a malformed token keeps its label")
  func malformedTokenIgnored() throws {
    let tracks = energies(seconds: 4, mic: [1...3], system: [])
    let tokens = [
      TranscriptToken(text: "a", startMs: 2000, endMs: 1500, speaker: 2),
      TranscriptToken(text: "b", startMs: .nan, endMs: 2000, speaker: 2),
      TranscriptToken(text: "c", startMs: 2000, endMs: 2000, speaker: 2),
    ]
    let outcome = MicAttribution.attribute(tokens: tokens, energies: tracks)
    #expect(try #require(localIndices(outcome)) == [2])
  }

  @Test("short pauses are bridged and short blips are dropped")
  func smoothing() {
    var active = [true, true, false, false, true] + Array(repeating: false, count: 20) + [true]
    MicAttribution.fillGaps(&active, upTo: 2)
    #expect(Array(active.prefix(5)) == [true, true, true, true, true])
    #expect(active[24] == false)
    MicAttribution.dropRuns(&active, shorterThan: 2)
    #expect(Array(active.prefix(5)) == [true, true, true, true, true])
    #expect(active.last == false)
  }

  // MARK: Decode on a real two-track file

  @Test("a two-track recording attributes mic-only speech")
  func analyzesTwoTrackFile() async throws {
    let url = try await Self.writeRecording(
      seconds: 8, systemChannels: 2, micBursts: [1...2, 5...6], systemBursts: [3...4, 5...6])
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let tokens = [token(at: 1.5), token(at: 3.5), token(at: 5.5), token(at: 7.2)]

    let outcome = try await MicAttribution.analyze(audioURL: url, tokens: tokens)

    #expect(try #require(localIndices(outcome)) == [0])
  }

  @Test("a mono plus mono recording (v0.7) is ineligible")
  func monoMonoIneligible() async throws {
    let url = try await Self.writeRecording(
      seconds: 3, systemChannels: 1, micBursts: [1...2], systemBursts: [])
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let outcome = try await MicAttribution.analyze(audioURL: url, tokens: [token(at: 1.5)])

    guard case .ineligible = outcome else {
      Issue.record("expected ineligible, got \(outcome)")
      return
    }
  }

  @Test("a single-track recording is ineligible")
  func singleTrackIneligible() async throws {
    let url = try await Self.writeRecording(
      seconds: 2, systemChannels: 2, micBursts: nil, systemBursts: [0.5...1])
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let outcome = try await MicAttribution.analyze(audioURL: url, tokens: [token(at: 1)])

    guard case .ineligible = outcome else {
      Issue.record("expected ineligible, got \(outcome)")
      return
    }
  }

  /// Writes the current recorder layout: track 0 system (`systemChannels`),
  /// track 1 mono mic, both AAC at 48 kHz, with a 440 Hz tone inside each burst.
  /// `micBursts: nil` writes no mic track at all.
  static func writeRecording(
    seconds: Double, systemChannels: Int, micBursts: [ClosedRange<Double>]?,
    systemBursts: [ClosedRange<Double>]
  ) async throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("blackbox-attribution-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("audio.m4a")
    let writer = try AVAssetWriter(url: url, fileType: .m4a)

    func makeInput(channels: Int) -> AVAssetWriterInput {
      let input = AVAssetWriterInput(
        mediaType: .audio,
        outputSettings: [
          AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000.0,
          AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: 64_000 * channels,
        ])
      input.expectsMediaDataInRealTime = true
      writer.add(input)
      return input
    }
    var tracks = [(makeInput(channels: systemChannels), systemChannels, systemBursts)]
    if let micBursts { tracks.append((makeInput(channels: 1), 1, micBursts)) }

    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    let chunk = 1024
    let total = Int(seconds * 48_000)
    var offset = 0
    while offset < total {
      let frames = min(chunk, total - offset)
      for (input, channels, bursts) in tracks {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
        let buffer = try #require(
          makeBuffer(offset: offset, frames: frames, channels: channels, bursts: bursts))
        #expect(input.append(buffer))
      }
      offset += frames
    }
    for (input, _, _) in tracks { input.markAsFinished() }
    await writer.finishWriting()
    #expect(writer.status == .completed, "\(String(describing: writer.error))")
    return url
  }

  private static func makeBuffer(
    offset: Int, frames: Int, channels: Int, bursts: [ClosedRange<Double>]
  ) -> CMSampleBuffer? {
    var samples = [Float](repeating: 0, count: frames * channels)
    for frame in 0..<frames {
      let t = Double(offset + frame) / 48_000
      guard bursts.contains(where: { $0.contains(t) }) else { continue }
      let value = Float(sin(2 * Double.pi * 440 * t) * 0.3)
      for channel in 0..<channels { samples[frame * channels + channel] = value }
    }
    var asbd = AudioStreamBasicDescription(
      mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
      mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1,
      mBytesPerFrame: UInt32(4 * channels), mChannelsPerFrame: UInt32(channels),
      mBitsPerChannel: 32, mReserved: 0)
    var format: CMAudioFormatDescription?
    guard
      CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
        magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        == noErr, let format
    else { return nil }
    let length = samples.count * MemoryLayout<Float>.size
    var block: CMBlockBuffer?
    guard
      CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
        blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
        dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        == noErr, let block
    else { return nil }
    let replaced = samples.withUnsafeBytes { raw in
      CMBlockBufferReplaceDataBytes(
        with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
    }
    guard replaced == noErr else { return nil }
    var sample: CMSampleBuffer?
    guard
      CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
        sampleCount: frames, presentationTimeStamp: CMTime(value: Int64(offset), timescale: 48_000),
        packetDescriptions: nil, sampleBufferOut: &sample) == noErr
    else { return nil }
    return sample
  }
}

@Suite("Transcript Projection")
struct TranscriptProjectionTests {
  private let tokens = [
    TranscriptToken(text: "Hi", startMs: 0, endMs: 100, speaker: 1),
    TranscriptToken(text: " there", startMs: 200, endMs: 300, speaker: 1),
    TranscriptToken(text: " yes", startMs: 1000, endMs: 1100, speaker: 2),
    TranscriptToken(text: " ok", startMs: 1500, endMs: 1600, speaker: 1),
  ]

  @Test("without attribution, segments group by provider speaker")
  func groupsBySpeaker() {
    let segments = TranscriptDocument.segments(from: tokens)
    #expect(segments.map(\.speaker) == [1, 2, 1])
    #expect(segments.map(\.text) == ["Hi there", "yes", "ok"])
    #expect(segments.map(\.time) == [0, 1, 1.5])
  }

  @Test("local tokens from different speakers merge as You and split back on revert")
  func attributionIsReversible() {
    let attributed = TranscriptDocument.segments(from: tokens, localIndices: [1, 2])
    #expect(attributed.map(\.speaker) == [1, -1, 1])
    #expect(attributed[1].text == "there yes")

    let reverted = TranscriptDocument.segments(from: tokens)
    #expect(reverted.map(\.text) == ["Hi there", "yes", "ok"])
  }

  @Test("a malformed attribution field costs only itself")
  func malformedAttributionKeepsSegments() throws {
    let json = """
      {"segments":[{"speaker":1,"time":0,"text":"hello"}],
       "createdAt":"2026-11-03T12:00:00Z","attribution":"garbage","sourceAudio":7}
      """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let document = try decoder.decode(TranscriptDocument.self, from: Data(json.utf8))
    #expect(document.segments.count == 1)
    #expect(document.attribution == nil)
    #expect(document.sourceAudio == nil)
  }

  @Test("tokens are never written into transcript.json")
  func tokensStayOutOfTheTranscript() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("blackbox-projection-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var document = TranscriptDocument(
      segments: TranscriptDocument.segments(from: tokens), createdAt: Date())
    document.tokens = tokens
    try document.save(for: directory)

    let raw = try String(
      contentsOf: TranscriptDocument.sidecarURL(for: directory), encoding: .utf8)
    #expect(!raw.contains("tokens"))
  }

  @Test("a job record keeps the uploaded file name across a round trip")
  func jobRecordsSourceAudio() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("blackbox-job-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var job = TranscriptionJob(fileId: "f")
    job.sourceAudio = "audio.m4a"
    job.save(for: directory)
    #expect(TranscriptionJob.load(for: directory)?.sourceAudio == "audio.m4a")
  }
}
