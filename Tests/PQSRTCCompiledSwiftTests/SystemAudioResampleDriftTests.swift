import Foundation
import Testing

@testable import PQSRTC

@Suite(.serialized)
struct SystemAudioResampleDriftTests {

    /// ReplayKit delivers app audio at 44.1 kHz in 1024-frame buffers. 441 of
    /// them are exactly 10.24 s, which is 491_520 frames at 48 kHz. The WebRTC
    /// capture thread drains 10 ms (480-frame) chunks as audio arrives, so the
    /// frames served plus those still buffered must match the source duration.
    /// Any surplus is latency that grows for the whole share.
    @Test("44.1 kHz chunks resample to 48 kHz without rate drift")
    func chunkedResampleKeepsExactRate() throws {
        let mixer = ScreenShareSystemAudioMixer(targetSampleRate: 48_000, targetChannelCount: 1)
        mixer.activate()
        let chunk = try ScreenSharePCMFrame(
            samples: [Float](repeating: 0.25, count: 1_024),
            sampleRate: 44_100,
            channelCount: 1
        )

        var servedFrames = 0
        for _ in 0..<441 {
            mixer.push(chunk)
            while mixer.dequeueMixChunk(frameCount: 480) != nil {
                servedFrames += 480
            }
        }

        let producedFrames = servedFrames + mixer.bufferedFrameCount
        #expect(
            abs(producedFrames - 491_520) <= 1,
            "10.24 s of 44.1 kHz audio produced \(producedFrames) frames at 48 kHz, expected 491520"
        )
    }
}
