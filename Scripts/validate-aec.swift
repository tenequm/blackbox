#!/usr/bin/env swift
/// Validates AEC-processed audio files against their originals.
/// Run: swift Scripts/validate-aec.swift [recording-dir ...]
/// With no args, validates all processed recordings in the default directory.

import AVFoundation
import CoreMedia
import Foundation

// MARK: - Configuration

let defaultRecordingsDir = FileManager.default.homeDirectoryForCurrentUser
  .appendingPathComponent("Library/Application Support/Blackbox/Recordings")

let pcmSettings: [String: Any] = [
  AVFormatIDKey: kAudioFormatLinearPCM,
  AVSampleRateKey: 16000.0,
  AVNumberOfChannelsKey: 1,
  AVLinearPCMBitDepthKey: 32,
  AVLinearPCMIsFloatKey: true,
  AVLinearPCMIsBigEndianKey: false,
  AVLinearPCMIsNonInterleaved: false,
]

// MARK: - Validation

struct ValidationResult {
  let name: String
  var checks: [(String, Bool, String)] = []  // (check name, passed, detail)

  var passed: Bool { checks.allSatisfy { $0.1 } }

  mutating func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    checks.append((name, condition, detail))
  }
}

func validate(recordingDir: URL) -> ValidationResult {
  let name = recordingDir.lastPathComponent
  var result = ValidationResult(name: name)

  let audioURL = recordingDir.appendingPathComponent("audio.m4a")
  let processedURL = recordingDir.appendingPathComponent("audio-processed.m4a")

  guard FileManager.default.fileExists(atPath: audioURL.path) else {
    result.check("audio.m4a exists", false, "missing")
    return result
  }
  guard FileManager.default.fileExists(atPath: processedURL.path) else {
    result.check("audio-processed.m4a exists", false, "missing")
    return result
  }

  result.check("files exist", true)

  // Load assets
  let originalAsset = AVURLAsset(url: audioURL)
  let processedAsset = AVURLAsset(url: processedURL)

  // Check track count
  let origTracks = originalAsset.tracks(withMediaType: .audio)
  let procTracks = processedAsset.tracks(withMediaType: .audio)

  result.check("original has 2 tracks", origTracks.count == 2, "got \(origTracks.count)")
  result.check("processed has 2 tracks", procTracks.count == 2, "got \(procTracks.count)")

  guard procTracks.count == 2 else { return result }

  // Check format of each processed track
  for (i, track) in procTracks.enumerated() {
    let label = "track \(i)"
    guard let descAny = track.formatDescriptions.first else {
      result.check("\(label) format", false, "no format description")
      continue
    }
    let desc = descAny as! CMFormatDescription
    guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee else {
      result.check("\(label) format", false, "no ASBD")
      continue
    }
    result.check(
      "\(label) sample rate 16kHz", asbd.mSampleRate == 16000,
      "\(asbd.mSampleRate)Hz")
    result.check(
      "\(label) mono", asbd.mChannelsPerFrame == 1,
      "\(asbd.mChannelsPerFrame)ch")
  }

  // Check duration
  let origDur = CMTimeGetSeconds(originalAsset.duration)
  let procDur = CMTimeGetSeconds(processedAsset.duration)
  let durDiff = abs(procDur - origDur)
  result.check(
    "duration within 1s", durDiff < 1.0,
    "orig=\(String(format: "%.2f", origDur))s proc=\(String(format: "%.2f", procDur))s diff=\(String(format: "%.2f", durDiff))s"
  )

  // Check file sizes are reasonable
  let origSize = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int)
    ?? 0
  let procSize =
    (try? FileManager.default.attributesOfItem(atPath: processedURL.path)[.size] as? Int) ?? 0
  // Processed should be smaller (16kHz mono vs 48kHz stereo) but not empty
  result.check("processed file not empty", procSize > 1000, "\(procSize) bytes")
  if origSize > 0 {
    let ratio = Double(procSize) / Double(origSize)
    result.check(
      "size ratio reasonable", ratio > 0.1 && ratio < 2.0,
      "ratio=\(String(format: "%.2f", ratio))")
  }

  // Read mic track samples and check for non-silence
  if let micStats = readTrackStats(asset: processedAsset, trackIndex: 1) {
    result.check(
      "mic track has samples", micStats.sampleCount > 0,
      "\(micStats.sampleCount) samples")
    result.check(
      "mic track not silent", micStats.peakLevel > 0.001,
      "peak=\(String(format: "%.6f", micStats.peakLevel))")
    result.check(
      "mic RMS reasonable", micStats.rmsLevel > 0.0001,
      "rms=\(String(format: "%.6f", micStats.rmsLevel))")
  } else {
    result.check("mic track readable", false)
  }

  // Read system track and verify it has content too
  if let sysStats = readTrackStats(asset: processedAsset, trackIndex: 0) {
    result.check(
      "system track has samples", sysStats.sampleCount > 0,
      "\(sysStats.sampleCount) samples")
  } else {
    result.check("system track readable", false)
  }

  return result
}

// MARK: - Audio Analysis

struct TrackStats {
  var sampleCount: Int = 0
  var peakLevel: Float = 0
  var rmsLevel: Float = 0
  var perSecondRMS: [Float] = []
}

func readTrackStats(asset: AVURLAsset, trackIndex: Int) -> TrackStats? {
  let tracks = asset.tracks(withMediaType: .audio)
  guard tracks.count > trackIndex else { return nil }

  guard let reader = try? AVAssetReader(asset: asset) else { return nil }
  let output = AVAssetReaderTrackOutput(track: tracks[trackIndex], outputSettings: pcmSettings)
  output.alwaysCopiesSampleData = false
  reader.add(output)
  guard reader.startReading() else { return nil }

  var stats = TrackStats()
  var sumOfSquares: Double = 0
  var currentSecondSamples: [Float] = []
  let sampleRate = 16000

  while let buffer = output.copyNextSampleBuffer() {
    guard let blockBuffer = CMSampleBufferGetDataBuffer(buffer) else { continue }
    let length = CMBlockBufferGetDataLength(blockBuffer)
    let floatCount = length / MemoryLayout<Float>.size

    var data = [Float](repeating: 0, count: floatCount)
    data.withUnsafeMutableBufferPointer { ptr in
      guard let base = ptr.baseAddress else { return }
      _ = CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: base)
    }

    for sample in data {
      let abs = Swift.abs(sample)
      if abs > stats.peakLevel { stats.peakLevel = abs }
      sumOfSquares += Double(sample) * Double(sample)

      currentSecondSamples.append(sample)
      if currentSecondSamples.count >= sampleRate {
        stats.perSecondRMS.append(rms(currentSecondSamples))
        currentSecondSamples.removeAll(keepingCapacity: true)
      }
    }
    stats.sampleCount += floatCount
  }

  // Flush last partial second
  if !currentSecondSamples.isEmpty {
    stats.perSecondRMS.append(rms(currentSecondSamples))
  }

  if stats.sampleCount > 0 {
    stats.rmsLevel = Float((sumOfSquares / Double(stats.sampleCount)).squareRoot())
  }

  return stats
}

func rms(_ samples: [Float]) -> Float {
  guard !samples.isEmpty else { return 0 }
  var sum: Float = 0
  for s in samples { sum += s * s }
  return (sum / Float(samples.count)).squareRoot()
}

// MARK: - Comparison

func compareProcessedFiles(
  reference: URL, candidate: URL, name: String
) -> ValidationResult {
  var result = ValidationResult(name: "\(name) (vs reference)")

  let refAsset = AVURLAsset(url: reference)
  let candAsset = AVURLAsset(url: candidate)

  // Duration comparison
  let refDur = CMTimeGetSeconds(refAsset.duration)
  let candDur = CMTimeGetSeconds(candAsset.duration)
  result.check(
    "duration match", abs(refDur - candDur) < 0.5,
    "ref=\(String(format: "%.2f", refDur))s cand=\(String(format: "%.2f", candDur))s")

  // File size comparison
  let refSize =
    (try? FileManager.default.attributesOfItem(atPath: reference.path)[.size] as? Int) ?? 0
  let candSize =
    (try? FileManager.default.attributesOfItem(atPath: candidate.path)[.size] as? Int) ?? 0
  if refSize > 0 {
    let ratio = Double(candSize) / Double(refSize)
    result.check(
      "file size within 20%", ratio > 0.8 && ratio < 1.2,
      "ref=\(refSize) cand=\(candSize) ratio=\(String(format: "%.2f", ratio))")
  }

  // Per-second RMS comparison on mic track
  guard let refStats = readTrackStats(asset: refAsset, trackIndex: 1),
    let candStats = readTrackStats(asset: candAsset, trackIndex: 1)
  else {
    result.check("mic tracks readable", false)
    return result
  }

  let seconds = min(refStats.perSecondRMS.count, candStats.perSecondRMS.count)
  result.check("have per-second data", seconds > 0, "\(seconds) seconds")

  var maxDiff: Float = 0
  var worstSecond = 0
  for s in 0..<seconds {
    let diff = abs(refStats.perSecondRMS[s] - candStats.perSecondRMS[s])
    if diff > maxDiff {
      maxDiff = diff
      worstSecond = s
    }
  }
  result.check(
    "per-second RMS within 0.05", maxDiff < 0.05,
    "max diff=\(String(format: "%.4f", maxDiff)) at second \(worstSecond)")

  // Overall RMS comparison
  let rmsDiff = abs(refStats.rmsLevel - candStats.rmsLevel)
  result.check(
    "overall RMS match", rmsDiff < 0.02,
    "ref=\(String(format: "%.4f", refStats.rmsLevel)) cand=\(String(format: "%.4f", candStats.rmsLevel))"
  )

  return result
}

// MARK: - Main

func printResult(_ result: ValidationResult) {
  let icon = result.passed ? "PASS" : "FAIL"
  print("\(icon) \(result.name)")
  for (check, passed, detail) in result.checks {
    let mark = passed ? "  ok" : "  FAIL"
    let detailStr = detail.isEmpty ? "" : " (\(detail))"
    print("\(mark): \(check)\(detailStr)")
  }
  print()
}

var dirs: [URL] = []

if CommandLine.arguments.count > 1 {
  // Specific directories passed as arguments
  for arg in CommandLine.arguments.dropFirst() {
    dirs.append(URL(fileURLWithPath: arg))
  }
} else {
  // Find all recordings with processed files
  guard let contents = try? FileManager.default.contentsOfDirectory(
    at: defaultRecordingsDir,
    includingPropertiesForKeys: [.isDirectoryKey])
  else {
    print("Cannot read recordings directory: \(defaultRecordingsDir.path)")
    exit(1)
  }

  for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
    let isDir =
      (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    guard isDir else { continue }
    let processedURL = url.appendingPathComponent("audio-processed.m4a")
    if FileManager.default.fileExists(atPath: processedURL.path) {
      dirs.append(url)
    }
  }
}

guard !dirs.isEmpty else {
  print("No processed recordings found to validate.")
  exit(0)
}

print("Validating \(dirs.count) processed recording(s)...\n")

var totalPassed = 0
var totalFailed = 0

for dir in dirs {
  let result = validate(recordingDir: dir)
  printResult(result)
  if result.passed { totalPassed += 1 } else { totalFailed += 1 }
}

print("Summary: \(totalPassed) passed, \(totalFailed) failed out of \(dirs.count) recordings")

if totalFailed > 0 {
  exit(1)
}
