@preconcurrency import AVFAudio
import CoreMedia
import Testing

@testable import Blackbox

@Suite("PCM-to-CMSampleBuffer Conversion")
struct PCMConversionTests {

  /// Create a synthetic AVAudioPCMBuffer with known sample data.
  private func makePCMBuffer(
    sampleRate: Double = 48000, channels: UInt32 = 2, frameCount: UInt32 = 1024
  ) -> AVAudioPCMBuffer? {
    guard
      let format = AVAudioFormat(
        standardFormatWithSampleRate: sampleRate, channels: channels)
    else { return nil }
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
    else { return nil }
    buffer.frameLength = frameCount

    // Fill with a simple sine wave so we can verify data survives conversion
    if let floatData = buffer.floatChannelData {
      for ch in 0..<Int(channels) {
        for i in 0..<Int(frameCount) {
          floatData[ch][i] = sin(Float(i) * 0.1)
        }
      }
    }
    return buffer
  }

  @Test("converts stereo 48kHz buffer successfully")
  func convertsStereo48kHz() {
    let pcm = makePCMBuffer(sampleRate: 48000, channels: 2, frameCount: 1024)!
    let result = pcm.asSampleBuffer()
    #expect(result != nil)
  }

  @Test("converts mono 44.1kHz buffer successfully")
  func convertsMono441kHz() {
    let pcm = makePCMBuffer(sampleRate: 44100, channels: 1, frameCount: 512)!
    let result = pcm.asSampleBuffer()
    #expect(result != nil)
  }

  @Test("preserves sample count")
  func preservesSampleCount() {
    let frameCount: UInt32 = 1024
    let pcm = makePCMBuffer(frameCount: frameCount)!
    let sb = pcm.asSampleBuffer()!
    #expect(CMSampleBufferGetNumSamples(sb) == Int(frameCount))
  }

  @Test("preserves sample rate in format description")
  func preservesSampleRate() {
    let pcm = makePCMBuffer(sampleRate: 48000)!
    let sb = pcm.asSampleBuffer()!
    let fmt = CMSampleBufferGetFormatDescription(sb)!
    let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)!.pointee
    #expect(asbd.mSampleRate == 48000)
  }

  @Test("has valid presentation timestamp")
  func hasValidTimestamp() {
    let pcm = makePCMBuffer()!
    let sb = pcm.asSampleBuffer()!
    let pts = CMSampleBufferGetPresentationTimeStamp(sb)
    #expect(pts.isValid)
    #expect(pts.seconds > 0)
  }

  @Test("output contains audio data")
  func containsAudioData() {
    let pcm = makePCMBuffer(frameCount: 1024)!
    let sb = pcm.asSampleBuffer()!
    let blockBuffer = CMSampleBufferGetDataBuffer(sb)
    #expect(blockBuffer != nil)
    #expect(CMBlockBufferGetDataLength(blockBuffer!) > 0)
  }
}
