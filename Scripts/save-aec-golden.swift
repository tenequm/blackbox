#!/usr/bin/env swift
/// Saves per-second RMS profiles from processed recordings as golden reference files.
/// These can be compared after refactoring to verify output is identical.
/// Run: swift Scripts/save-aec-golden.swift

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

func readTrackSamples(asset: AVURLAsset, trackIndex: Int) -> (
  count: Int, peak: Float, rms: Float, perSecondRMS: [Float]
)? {
  let tracks = asset.tracks(withMediaType: .audio)
  guard tracks.count > trackIndex else { return nil }
  guard let reader = try? AVAssetReader(asset: asset) else { return nil }
  let output = AVAssetReaderTrackOutput(track: tracks[trackIndex], outputSettings: pcmSettings)
  output.alwaysCopiesSampleData = false
  reader.add(output)
  guard reader.startReading() else { return nil }

  var totalCount = 0
  var peak: Float = 0
  var sumSq: Double = 0
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
      let a = Swift.abs(s)
      if a > peak { peak = a }
      sumSq += Double(s) * Double(s)
      secSamples.append(s)
      if secSamples.count >= 16000 {
        var ss: Float = 0
        for x in secSamples { ss += x * x }
        secRMS.append((ss / Float(secSamples.count)).squareRoot())
        secSamples.removeAll(keepingCapacity: true)
      }
    }
    totalCount += n
  }
  if !secSamples.isEmpty {
    var ss: Float = 0
    for x in secSamples { ss += x * x }
    secRMS.append((ss / Float(secSamples.count)).squareRoot())
  }
  let rms = totalCount > 0 ? Float((sumSq / Double(totalCount)).squareRoot()) : 0
  return (totalCount, peak, rms, secRMS)
}

// Create golden directory
try? FileManager.default.removeItem(at: goldenDir)
try FileManager.default.createDirectory(at: goldenDir, withIntermediateDirectories: true)

let contents = try FileManager.default.contentsOfDirectory(
  at: recordingsDir, includingPropertiesForKeys: [.isDirectoryKey])

var saved = 0
for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
  let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
  guard isDir else { continue }
  let processedURL = url.appendingPathComponent("audio-processed.m4a")
  guard FileManager.default.fileExists(atPath: processedURL.path) else { continue }

  let name = url.lastPathComponent
  let asset = AVURLAsset(url: processedURL)
  let dur = CMTimeGetSeconds(asset.duration)
  let size =
    (try? FileManager.default.attributesOfItem(atPath: processedURL.path)[.size] as? Int) ?? 0
  let trackCount = asset.tracks(withMediaType: .audio).count

  guard let mic = readTrackSamples(asset: asset, trackIndex: 1),
    let sys = readTrackSamples(asset: asset, trackIndex: 0)
  else {
    print("SKIP \(name): cannot read tracks")
    continue
  }

  let profile = GoldenProfile(
    name: name,
    duration: dur,
    fileSize: size,
    trackCount: trackCount,
    micSampleCount: mic.count,
    micPeakLevel: mic.peak,
    micRMSLevel: mic.rms,
    micPerSecondRMS: mic.perSecondRMS,
    sysSampleCount: sys.count
  )

  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  let data = try encoder.encode(profile)
  let outFile = goldenDir.appendingPathComponent("\(name).json")
  try data.write(to: outFile)
  print("SAVED \(name) (\(mic.perSecondRMS.count) seconds)")
  saved += 1
}

print("\n\(saved) golden profiles saved to: \(goldenDir.path)")
print("After refactoring, re-process recordings and run:")
print("  swift Scripts/compare-aec-golden.swift")
