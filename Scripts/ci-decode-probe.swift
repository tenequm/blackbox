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
