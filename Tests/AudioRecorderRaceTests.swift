import CoreGraphics
import Foundation
import Testing

@testable import Blackbox

/// Non-prompting capability check, the same source of truth the app itself uses
/// for this permission. Top-level so the `@Test` macro's `Sendable` closure can
/// reference it.
private nonisolated let screenRecordingGranted: Bool = CGPreflightScreenCaptureAccess()

@Suite("AudioRecorder Start/Stop Race")
struct AudioRecorderRaceTests {

  private func makeTempSaveDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "blackbox-race-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func cleanup(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }

  private func listM4As(under root: URL) -> [URL] {
    var out: [URL] = []
    let fm = FileManager.default
    guard
      let contents = try? fm.contentsOfDirectory(
        at: root, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey])
    else { return out }
    for entry in contents {
      let isDir =
        (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
      if isDir {
        out.append(contentsOf: listM4As(under: entry))
      } else if entry.pathExtension == "m4a" {
        out.append(entry)
      }
    }
    return out
  }

  @Test("stop arriving before content discovery leaves no on-disk artifact")
  func stopBeforeContentDiscovery_noOrphanArtifacts() async throws {
    let saveDir = try makeTempSaveDirectory()
    defer { cleanup(saveDir) }

    let gate = StartGate()
    let recorder = AudioRecorder(
      appName: "RaceTest",
      micEnabled: false,
      saveDirectory: saveDir,
      testStartCheckpoint: { checkpoint in
        if checkpoint == .beforeContent {
          await gate.suspend()
        }
      }
    )

    // Snapshot directory contents before start so we can compare after.
    let beforeContents = try FileManager.default.contentsOfDirectory(
      at: saveDir, includingPropertiesForKeys: nil)

    let startTask = Task { try await recorder.start() }
    await gate.waitForSuspended()

    let stopResult = await recorder.stop()
    await gate.release()

    let startResult = await startTask.result
    switch startResult {
    case .success:
      Issue.record("start() should have thrown after stop arrived during .beforeContent")
    case .failure(let error):
      guard case RecorderError.cancelled = error else {
        Issue.record("expected RecorderError.cancelled, got \(error)")
        return
      }
    }
    #expect(stopResult == nil)

    // Second stop is a no-op.
    let stopAgain = await recorder.stop()
    #expect(stopAgain == nil)

    let afterContents = try FileManager.default.contentsOfDirectory(
      at: saveDir, includingPropertiesForKeys: nil)
    let beforeSet = Set(beforeContents.map(\.lastPathComponent))
    let newEntries = afterContents.filter { !beforeSet.contains($0.lastPathComponent) }
    #expect(newEntries.isEmpty, "no recording dirs should remain on disk: \(newEntries)")
  }

  /// Reaches ScreenCaptureKit for real: `start()` discovers a display and builds
  /// an `SCStream` before the `.afterPipeline` checkpoint this suspends on, so
  /// the process needs Screen Recording permission.
  ///
  /// Gated on whether that permission actually exists rather than on an opt-in
  /// environment variable, which nothing set and so ran nowhere. Without it
  /// `waitForDisplay` polls for five minutes before giving up, so an ungated
  /// run on a machine without the grant hangs rather than failing. It runs on a
  /// developer machine, where TCC credits the terminal's grant to its children;
  /// it skips on a hosted runner, where the seeded grant is keyed to the app
  /// bundle and this process is a different client.
  @Test(
    "stop arriving after pipeline created leaves no zero-byte file",
    .enabled(if: screenRecordingGranted)
  )
  func stopAfterPipelineCreated_noZeroByteFile() async throws {
    let saveDir = try makeTempSaveDirectory()
    defer { cleanup(saveDir) }

    let gate = StartGate()
    let recorder = AudioRecorder(
      appName: "RaceTest",
      micEnabled: false,
      saveDirectory: saveDir,
      testStartCheckpoint: { checkpoint in
        if checkpoint == .afterPipeline {
          await gate.suspend()
        }
      }
    )

    let startTask = Task { try await recorder.start() }
    await gate.waitForSuspended()

    let stopResult = await recorder.stop()
    await gate.release()

    let startResult = await startTask.result
    switch startResult {
    case .success:
      Issue.record("start() should have thrown after stop during .afterPipeline")
    case .failure(let error):
      guard case RecorderError.cancelled = error else {
        Issue.record("expected RecorderError.cancelled, got \(error)")
        return
      }
    }
    #expect(stopResult == nil)

    // Walk the entire save dir; assert no audio file exists. Cancellation
    // must produce zero on-disk artifacts.
    let m4aFiles = listM4As(under: saveDir)
    for url in m4aFiles {
      let size =
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      Issue.record("unexpected m4a left on disk at \(url.path) size=\(size)")
    }
  }

  @Test("calling stop twice on a never-started recorder is a no-op")
  func doubleStop_idempotent() async throws {
    let saveDir = try makeTempSaveDirectory()
    defer { cleanup(saveDir) }

    let recorder = AudioRecorder(
      appName: "RaceTest",
      micEnabled: false,
      saveDirectory: saveDir
    )

    let first = await recorder.stop()
    let second = await recorder.stop()
    #expect(first == nil)
    #expect(second == nil)
  }
}
