#!/usr/bin/env swift
/// Compares current processed recordings against golden reference profiles.
/// Run after re-processing recordings with refactored AEC code.
/// Usage: swift Scripts/compare-aec-golden.swift

import AVFoundation
import CoreMedia
import Foundation

let recordingsDir = FileManager.default.homeDirectoryForCurrentUser
  .appendingPathComponent("Library/Application Support/Blackbox/Recordings")
let goldenDir = FileManager.default.temporaryDirectory
  .appendingPathComponent("blackbox-aec-golden")

let pcmSettings: [String: Any] = [
  AVFormatIDKey: kAudioFormatLinearPCM,
  AVSampleRateKey: 16000.0,
  AVNumberOfChannelsKey: 1,
  AVLinearPCMBitDepthKey: 32,
  AVLinearPCMIsFloatKey: true,
  AVLinearPCMIsBigEndianKey: false,
  AVLinearPCMIsNonInterleaved: false,
]

struct GoldenProfile: Codable {
  let name: String
  let duration: Double
  let fileSize: Int
  let trackCount: Int
  let micSampleCount: Int
  let micPeakLevel: Float
  let micRMSLevel: Float
  let micPerSecondRMS: [Float]
  let sysSampleCount: Int
}

func readPerSecondRMS(asset: AVURLAsset, trackIndex: Int) -> [Float]? {
  let tracks = asset.tracks(withMediaType: .audio)
  guard tracks.count > trackIndex else { return nil }
  guard let reader = try? AVAssetReader(asset: asset) else { return nil }
  let output = AVAssetReaderTrackOutput(track: tracks[trackIndex], outputSettings: pcmSettings)
  output.alwaysCopiesSampleData = false
  reader.add(output)
  guard reader.startReading() else { return nil }

  var secSamples: [Float] = []
  var secRMS: [Float] = []

  while let buffer = output.copyNextSampleBuffer() {
    guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
    let len = CMBlockBufferGetDataLength(block)
    let n = len / MemoryLayout<Float>.size
    var data = [Float](repeating: 0, count: n)
    data.withUnsafeMutableBufferPointer { p in
      _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: p.baseAddress!)
    }
    for s in data {
      secSamples.append(s)
      if secSamples.count >= 16000 {
        var ss: Float = 0
        for x in secSamples { ss += x * x }
        secRMS.append((ss / Float(secSamples.count)).squareRoot())
        secSamples.removeAll(keepingCapacity: true)
      }
    }
  }
  if !secSamples.isEmpty {
    var ss: Float = 0
    for x in secSamples { ss += x * x }
    secRMS.append((ss / Float(secSamples.count)).squareRoot())
  }
  return secRMS
}

// Load golden profiles
guard FileManager.default.fileExists(atPath: goldenDir.path) else {
  print("No golden profiles found at \(goldenDir.path)")
  print("Run: swift Scripts/save-aec-golden.swift first")
  exit(1)
}

let goldenFiles = try FileManager.default.contentsOfDirectory(
  at: goldenDir, includingPropertiesForKeys: nil
).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }

guard !goldenFiles.isEmpty else {
  print("No golden profiles found")
  exit(1)
}

print("Comparing \(goldenFiles.count) recording(s) against golden profiles...\n")

var passed = 0
var failed = 0

for goldenFile in goldenFiles {
  let data = try Data(contentsOf: goldenFile)
  let golden = try JSONDecoder().decode(GoldenProfile.self, from: data)

  let recDir = recordingsDir.appendingPathComponent(golden.name)
  let processedURL = recDir.appendingPathComponent("audio-processed.m4a")

  guard FileManager.default.fileExists(atPath: processedURL.path) else {
    print("SKIP \(golden.name): no processed file")
    continue
  }

  var checks: [(String, Bool, String)] = []

  let asset = AVURLAsset(url: processedURL)
  let dur = CMTimeGetSeconds(asset.duration)
  let size =
    (try? FileManager.default.attributesOfItem(atPath: processedURL.path)[.size] as? Int) ?? 0
  let trackCount = asset.tracks(withMediaType: .audio).count

  // Duration
  let durDiff = abs(dur - golden.duration)
  checks.append(("duration", durDiff < 0.5, "golden=\(String(format: "%.2f", golden.duration))s current=\(String(format: "%.2f", dur))s"))

  // Track count
  checks.append(("tracks", trackCount == golden.trackCount, "golden=\(golden.trackCount) current=\(trackCount)"))

  // File size within 20%
  if golden.fileSize > 0 {
    let ratio = Double(size) / Double(golden.fileSize)
    checks.append(("file size", ratio > 0.8 && ratio < 1.2, "golden=\(golden.fileSize) current=\(size) ratio=\(String(format: "%.2f", ratio))"))
  }

  // Per-second RMS comparison
  if let currentRMS = readPerSecondRMS(asset: asset, trackIndex: 1) {
    let seconds = min(golden.micPerSecondRMS.count, currentRMS.count)
    var maxDiff: Float = 0
    var worstSec = 0
    for s in 0..<seconds {
      let diff = abs(golden.micPerSecondRMS[s] - currentRMS[s])
      if diff > maxDiff { maxDiff = diff; worstSec = s }
    }
    checks.append(("per-second RMS", maxDiff < 0.05, "maxDiff=\(String(format: "%.4f", maxDiff)) at sec \(worstSec)"))

    // Overall RMS
    let goldenOverall = golden.micRMSLevel
    var currentSum: Float = 0
    for r in currentRMS { currentSum += r * r }
    let currentOverall = currentRMS.isEmpty ? Float(0) : (currentSum / Float(currentRMS.count)).squareRoot()
    let rmsDiff = abs(goldenOverall - currentOverall)
    checks.append(("overall RMS", rmsDiff < 0.02, "golden=\(String(format: "%.4f", goldenOverall)) current=\(String(format: "%.4f", currentOverall))"))

    // Second count should match (per-second RMS granularity)
    let secDiff = abs(golden.micPerSecondRMS.count - currentRMS.count)
    checks.append(("second count", secDiff <= 1, "golden=\(golden.micPerSecondRMS.count)s current=\(currentRMS.count)s"))
  } else {
    checks.append(("mic track readable", false, ""))
  }

  let allPassed = checks.allSatisfy { $0.1 }
  let icon = allPassed ? "PASS" : "FAIL"
  print("\(icon) \(golden.name)")
  for (name, ok, detail) in checks {
    let mark = ok ? "  ok" : "  FAIL"
    print("\(mark): \(name) (\(detail))")
  }
  print()

  if allPassed { passed += 1 } else { failed += 1 }
}

print("Summary: \(passed) passed, \(failed) failed")
if failed > 0 { exit(1) }
