import AVFoundation
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let mode = CommandLine.arguments[2]
let t0 = Date()
func done(_ s: String) { print(String(format: "%@: %@ in %.2fs", mode, s, Date().timeIntervalSince(t0))); exit(0) }
DispatchQueue.global().asyncAfter(deadline: .now() + 20) { print("\(mode): TIMEOUT after 20s"); exit(2) }
if mode == "avaudiofile" {
  let f = try! AVAudioFile(forReading: url)
  let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 48000)!
  var n = 0; while f.framePosition < f.length { try! f.read(into: buf, frameCount: 48000); n += Int(buf.frameLength) }
  done("read \(n) frames")
} else if mode == "tworeaders" {
  // Mirrors AECProcessor.run: two readers on one asset, interleaved single-threaded reads.
  let asset = AVURLAsset(url: url)
  let sem = DispatchSemaphore(value: 0)
  Task {
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVNumberOfChannelsKey: 1, AVSampleRateKey: 16000, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
    let r1 = try AVAssetReader(asset: asset); let o1 = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: settings); o1.alwaysCopiesSampleData = false; r1.add(o1)
    let r2 = try AVAssetReader(asset: asset); let o2 = AVAssetReaderTrackOutput(track: tracks[1], outputSettings: settings); o2.alwaysCopiesSampleData = false; r2.add(o2)
    print("start:", r1.startReading(), r2.startReading())
    var n1 = 0, n2 = 0, d1 = false, d2 = false, i = 0
    while !(d1 && d2) {
      if !d1 { if let sb = o1.copyNextSampleBuffer() { n1 += CMSampleBufferGetNumSamples(sb) } else { d1 = true } }
      if !d2 { if let sb = o2.copyNextSampleBuffer() { n2 += CMSampleBufferGetNumSamples(sb) } else { d2 = true } }
      i += 1; if i % 20 == 0 { print("  iter \(i): sys=\(n1) mic=\(n2)") }
    }
    done("sys=\(n1) mic=\(n2)"); sem.signal()
  }
  sem.wait()
} else {
  let asset = AVURLAsset(url: url)
  let sem = DispatchSemaphore(value: 0)
  Task {
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    let r = try AVAssetReader(asset: asset)
    let o = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVNumberOfChannelsKey: 1, AVSampleRateKey: 16000])
    r.add(o); print("startReading:", r.startReading(), r.status.rawValue)
    var n = 0; while let sb = o.copyNextSampleBuffer() { n += CMSampleBufferGetNumSamples(sb) }
    print("reader status:", r.status.rawValue, r.error?.localizedDescription ?? "")
    done("read \(n) samples"); sem.signal()
  }
  sem.wait()
}
