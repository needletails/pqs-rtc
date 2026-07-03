import Foundation
import Testing

@testable import PQSRTC

@Suite(.serialized)
struct ScreenShareSystemAudioContractTests {

    @Test("10ms mix chunk size matches WebRTC capture step")
    func samplesPerFrameMatchesWebRTCExpectation() {
        #expect(ScreenShareSystemAudioContract.samplesPerChannelPerFrame(sampleRate: 48_000) == 480)
        #expect(ScreenShareSystemAudioContract.samplesPerChannelPerFrame(sampleRate: 44_100) == 441)
        #expect(ScreenShareSystemAudioContract.samplesPerChannelPerFrame(sampleRate: 16_000) == 160)
    }

    @Test("capture defaults are 48kHz stereo")
    func captureDefaults() {
        #expect(ScreenShareSystemAudioContract.captureSampleRate == 48_000)
        #expect(ScreenShareSystemAudioContract.captureChannelCount == 2)
        #expect(ScreenShareSystemAudioContract.webrtcFloatS16FullScale == 32_768)
        #expect(ScreenShareSystemAudioContract.systemAudioMixGain == Float(1.0))
    }
}

@Suite(.serialized)
struct ScreenSharePCMFrameTests {

    @Test("frame validates sample alignment and format")
    func frameValidation() throws {
        let frame = try ScreenSharePCMFrame(samples: [0.1, 0.2, 0.3, 0.4], sampleRate: 48_000, channelCount: 2)
        #expect(frame.frameCount == 2)
        #expect(abs(frame.durationSeconds - 2.0 / 48_000.0) < 1e-9)

        #expect(throws: ScreenShareSystemAudioError.self) {
            try ScreenSharePCMFrame(samples: [0.1, 0.2, 0.3], sampleRate: 48_000, channelCount: 2)
        }
        #expect(throws: ScreenShareSystemAudioError.self) {
            try ScreenSharePCMFrame(samples: [], sampleRate: 48_000, channelCount: 1)
        }
        #expect(throws: ScreenShareSystemAudioError.self) {
            try ScreenSharePCMFrame(samples: [0.1], sampleRate: 0, channelCount: 1)
        }
        #expect(throws: ScreenShareSystemAudioError.self) {
            try ScreenSharePCMFrame(samples: [0.1], sampleRate: 48_000, channelCount: 0)
        }
    }
}

@Suite(.serialized)
struct ScreenShareSystemAudioMixerTests {

    private func makeActiveMixer(sampleRate: Int = 48_000, channels: Int = 2) -> ScreenShareSystemAudioMixer {
        let mixer = ScreenShareSystemAudioMixer(targetSampleRate: sampleRate, targetChannelCount: channels)
        mixer.activate()
        return mixer
    }

    @Test("inactive mixer ignores pushes and serves nothing")
    func inactiveMixerIsSilent() throws {
        let mixer = ScreenShareSystemAudioMixer(targetSampleRate: 48_000, targetChannelCount: 1)
        let frame = try ScreenSharePCMFrame(
            samples: [Float](repeating: 0.5, count: 480),
            sampleRate: 48_000,
            channelCount: 1
        )
        mixer.push(frame)
        #expect(mixer.bufferedFrameCount == 0)
        #expect(mixer.dequeueMixChunk(frameCount: 480) == nil)
    }

    @Test("matching-format pushes round-trip exactly")
    func matchingFormatRoundTrip() throws {
        let mixer = makeActiveMixer(channels: 2)
        let samples: [Float] = [0.1, -0.1, 0.2, -0.2, 0.3, -0.3]
        mixer.push(try ScreenSharePCMFrame(samples: samples, sampleRate: 48_000, channelCount: 2))

        #expect(mixer.bufferedFrameCount == 3)
        let chunk = mixer.dequeueMixChunk(frameCount: 3)
        #expect(chunk == samples)
        #expect(mixer.bufferedFrameCount == 0)
    }

    @Test("short buffer waits for a full frame instead of zero-padding")
    func underflowReturnsNilUntilFullFrame() throws {
        let mixer = makeActiveMixer(channels: 1)
        mixer.push(try ScreenSharePCMFrame(samples: [0.5, 0.5], sampleRate: 48_000, channelCount: 1))

        #expect(mixer.dequeueMixChunk(frameCount: 4) == nil)
        #expect(mixer.bufferedFrameCount == 2)

        mixer.push(try ScreenSharePCMFrame(samples: [0.25, 0.25], sampleRate: 48_000, channelCount: 1))
        let chunk = mixer.dequeueMixChunk(frameCount: 4)
        #expect(chunk == [0.5, 0.5, 0.25, 0.25])
        #expect(mixer.bufferedFrameCount == 0)
    }

    @Test("remainder carries across dequeues once a full frame is available")
    func remainderCarriesAcrossCalls() throws {
        let mixer = makeActiveMixer(channels: 1)
        let samples = (0..<10).map { Float($0) / 10 }
        mixer.push(try ScreenSharePCMFrame(samples: samples, sampleRate: 48_000, channelCount: 1))

        #expect(mixer.dequeueMixChunk(frameCount: 4) == Array(samples[0..<4]))
        #expect(mixer.dequeueMixChunk(frameCount: 4) == Array(samples[4..<8]))
        #expect(mixer.dequeueMixChunk(frameCount: 4) == nil)
        #expect(mixer.bufferedFrameCount == 2)
        #expect(mixer.dequeueMixChunk(frameCount: 2) == [samples[8], samples[9]])
    }

    @Test("mono input upmixes to stereo target")
    func monoUpmixesToStereo() throws {
        let mixer = makeActiveMixer(channels: 2)
        mixer.push(try ScreenSharePCMFrame(samples: [0.25, -0.5], sampleRate: 48_000, channelCount: 1))

        let chunk = mixer.dequeueMixChunk(frameCount: 2)
        #expect(chunk == [0.25, 0.25, -0.5, -0.5])
    }

    @Test("stereo input downmixes to mono target by averaging")
    func stereoDownmixesToMono() throws {
        let mixer = makeActiveMixer(channels: 1)
        mixer.push(try ScreenSharePCMFrame(samples: [0.2, 0.4, -0.2, -0.4], sampleRate: 48_000, channelCount: 2))

        let chunk = try #require(mixer.dequeueMixChunk(frameCount: 2))
        #expect(abs(chunk[0] - 0.3) < 1e-6)
        #expect(abs(chunk[1] - (-0.3)) < 1e-6)
    }

    @Test("44.1kHz input resamples to 48kHz target")
    func resamples44kTo48k() throws {
        let mixer = makeActiveMixer(sampleRate: 48_000, channels: 1)
        // 441 samples at 44.1 kHz = 10 ms → ~480 samples at 48 kHz.
        let source = [Float](repeating: 0.5, count: 441)
        mixer.push(try ScreenSharePCMFrame(samples: source, sampleRate: 44_100, channelCount: 1))

        let buffered = mixer.bufferedFrameCount
        #expect(abs(buffered - 480) <= 1)
        let chunk = try #require(mixer.dequeueMixChunk(frameCount: buffered))
        // Constant signal stays constant through linear resampling.
        #expect(chunk.allSatisfy { abs($0 - 0.5) < 1e-5 })
    }

    @Test("resampler preserves a linear ramp")
    func resamplerPreservesRamp() {
        let source = (0..<100).map { Float($0) / 100 }
        let output = ScreenShareSystemAudioMixer.resampleLinear(
            interleaved: source,
            channelCount: 1,
            from: 24_000,
            to: 48_000
        )
        #expect(output.count == 200)
        #expect(abs(output.first! - 0.0) < 1e-6)
        #expect(abs(output.last! - 0.99) < 1e-6)
        // Monotonic non-decreasing ramp must stay monotonic.
        for index in 1..<output.count {
            #expect(output[index] + 1e-6 >= output[index - 1])
        }
    }

    @Test("buffer overflow drops oldest samples and stays channel-aligned")
    func overflowDropsOldest() throws {
        let mixer = makeActiveMixer(sampleRate: 1_000, channels: 2)
        // Cap: 1000 Hz * 500 ms = 500 frames.
        let first = try ScreenSharePCMFrame(
            samples: [Float](repeating: 0.1, count: 900 * 2),
            sampleRate: 1_000,
            channelCount: 2
        )
        let second = try ScreenSharePCMFrame(
            samples: [Float](repeating: 0.9, count: 200 * 2),
            sampleRate: 1_000,
            channelCount: 2
        )
        mixer.push(first)
        mixer.push(second)

        #expect(mixer.bufferedFrameCount <= 500)
        // Drain everything; the newest samples (0.9) must survive.
        let chunk = try #require(mixer.dequeueMixChunk(frameCount: mixer.bufferedFrameCount))
        #expect(chunk.count.isMultiple(of: 2))
        #expect(abs(chunk.last! - 0.9) < 1e-6)
    }

    @Test("deactivate clears buffered audio")
    func deactivateClearsBuffer() throws {
        let mixer = makeActiveMixer(channels: 1)
        mixer.push(try ScreenSharePCMFrame(
            samples: [Float](repeating: 0.5, count: 480),
            sampleRate: 48_000,
            channelCount: 1
        ))
        #expect(mixer.bufferedFrameCount == 480)

        mixer.deactivate()
        #expect(mixer.bufferedFrameCount == 0)
        #expect(mixer.dequeueMixChunk(frameCount: 480) == nil)

        // Reactivation starts clean.
        mixer.activate()
        #expect(mixer.dequeueMixChunk(frameCount: 480) == nil)
    }

    @Test("target reconfiguration drops stale-format audio")
    func reconfigureDropsStaleAudio() throws {
        let mixer = makeActiveMixer(sampleRate: 48_000, channels: 1)
        mixer.push(try ScreenSharePCMFrame(
            samples: [Float](repeating: 0.5, count: 480),
            sampleRate: 48_000,
            channelCount: 1
        ))
        #expect(mixer.bufferedFrameCount == 480)

        mixer.configureTarget(sampleRate: 16_000, channelCount: 1)
        #expect(mixer.bufferedFrameCount == 0)

        // Same-format reconfigure is a no-op.
        mixer.push(try ScreenSharePCMFrame(
            samples: [Float](repeating: 0.5, count: 160),
            sampleRate: 16_000,
            channelCount: 1
        ))
        mixer.configureTarget(sampleRate: 16_000, channelCount: 1)
        #expect(mixer.bufferedFrameCount == 160)
    }
}

@Suite(.serialized)
struct ScreenShareSystemAudioEgressTests {

    /// Records calls for lifecycle assertions.
    final class RecordingEgress: ScreenShareSystemAudioEgress, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var activateCount = 0
        private(set) var deactivateCount = 0
        private(set) var pushedFrameCount = 0

        func activate() { lock.withLock { activateCount += 1 } }
        func deactivate() { lock.withLock { deactivateCount += 1 } }
        func push(_ frame: ScreenSharePCMFrame) { lock.withLock { pushedFrameCount += 1 } }
    }

    @Test("no-op egress discards everything")
    func noopEgressDiscards() throws {
        let egress = NoOpScreenShareSystemAudioEgress()
        egress.activate()
        egress.push(try ScreenSharePCMFrame(samples: [0.1], sampleRate: 48_000, channelCount: 1))
        egress.deactivate()
        // Nothing to assert beyond "does not crash" — type is stateless.
    }

#if canImport(WebRTC) && !os(Android)
    @Test("prepareForSystemAudioShare seeds mixer using last WebRTC capture format")
    func prepareForSystemAudioShareSeedsMixer() throws {
        let processor = ScreenShareSystemAudioCapturePostProcessor()
        processor.audioProcessingInitialize(sampleRate: 48_000, channels: 1)
        processor.prepareForSystemAudioShare()
        processor.mixer.activate()
        processor.mixer.push(try ScreenSharePCMFrame(
            samples: [Float](repeating: 0.25, count: 480),
            sampleRate: 48_000,
            channelCount: 1
        ))
        #expect(processor.mixer.bufferedFrameCount == 480)
    }

    @Test("WebRTC egress drives the shared processor mixer")
    func webRTCEgressDrivesMixer() throws {
        let processor = ScreenShareSystemAudioCapturePostProcessor()
        processor.audioProcessingInitialize(sampleRate: 48_000, channels: 1)
        let egress = WebRTCScreenShareSystemAudioEgress(processor: processor)

        egress.activate()
        #expect(processor.mixer.isActive)

        egress.push(try ScreenSharePCMFrame(
            samples: [Float](repeating: 0.25, count: 480),
            sampleRate: 48_000,
            channelCount: 1
        ))
        #expect(processor.mixer.bufferedFrameCount == 480)

        egress.deactivate()
        #expect(!processor.mixer.isActive)
        #expect(processor.mixer.bufferedFrameCount == 0)
    }

    @Test("processor release deactivates the mixer")
    func processorReleaseDeactivatesMixer() throws {
        let processor = ScreenShareSystemAudioCapturePostProcessor()
        processor.audioProcessingInitialize(sampleRate: 48_000, channels: 2)
        processor.mixer.activate()
        processor.mixer.push(try ScreenSharePCMFrame(
            samples: [Float](repeating: 0.5, count: 960),
            sampleRate: 48_000,
            channelCount: 2
        ))
        #expect(processor.mixer.bufferedFrameCount == 480)

        processor.audioProcessingRelease()
        #expect(!processor.mixer.isActive)
        #expect(processor.mixer.bufferedFrameCount == 0)
    }

    @Test("muted mic is suppressed while queued system audio is mixed")
    func mutedMicIsSuppressedWhileSystemAudioMixes() throws {
        let processor = ScreenShareSystemAudioCapturePostProcessor()
        processor.audioProcessingInitialize(sampleRate: 48_000, channels: 1)
        processor.setSuppressMicCapture(true)
        processor.mixer.activate()
        processor.mixer.push(try ScreenSharePCMFrame(
            samples: [0.25, -0.25, 0.5, -0.5],
            sampleRate: 48_000,
            channelCount: 1
        ))

        var micChannel: [Float] = [1_000, 1_000, 1_000, 1_000]
        micChannel.withUnsafeMutableBufferPointer { buffer in
            processor.processCaptureAudio(frames: 4, channels: 1) { _ in
                buffer.baseAddress!
            }
        }

        #expect(micChannel == [8_192, -8_192, 16_384, -16_384])
    }

    @Test("unmuted mic is mixed with queued system audio")
    func unmutedMicIsMixedWithSystemAudio() throws {
        let processor = ScreenShareSystemAudioCapturePostProcessor()
        processor.audioProcessingInitialize(sampleRate: 48_000, channels: 1)
        processor.setSuppressMicCapture(false)
        processor.mixer.activate()
        processor.mixer.push(try ScreenSharePCMFrame(
            samples: [0.25, -0.25],
            sampleRate: 48_000,
            channelCount: 1
        ))

        var micChannel: [Float] = [1_000, -1_000]
        micChannel.withUnsafeMutableBufferPointer { buffer in
            processor.processCaptureAudio(frames: 2, channels: 1) { _ in
                buffer.baseAddress!
            }
        }

        #expect(micChannel == [9_192, -9_192])
    }
#endif
}
