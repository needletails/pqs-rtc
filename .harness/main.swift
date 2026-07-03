// Standalone verification harness for the screen-share system-audio pipeline.
// Compiled directly against the WebRTC.xcframework because the package's
// SkipSwiftUI dependency currently fails to build on this toolchain.
// Mirrors the assertions in ScreenShareSystemAudioMixerTests /
// ScreenSharePCMSampleConverterTests.

import CoreMedia
import Foundation

var failures = 0
func expect(_ condition: Bool, _ label: String) {
    if condition {
        print("PASS \(label)")
    } else {
        failures += 1
        print("FAIL \(label)")
    }
}

// MARK: Contract

expect(ScreenShareSystemAudioContract.samplesPerChannelPerFrame(sampleRate: 48_000) == 480, "contract 48k frame")
expect(ScreenShareSystemAudioContract.samplesPerChannelPerFrame(sampleRate: 16_000) == 160, "contract 16k frame")

// MARK: Frame validation

do {
    let frame = try ScreenSharePCMFrame(samples: [0.1, 0.2, 0.3, 0.4], sampleRate: 48_000, channelCount: 2)
    expect(frame.frameCount == 2, "frame count")
} catch { expect(false, "frame init threw \(error)") }
do {
    _ = try ScreenSharePCMFrame(samples: [0.1, 0.2, 0.3], sampleRate: 48_000, channelCount: 2)
    expect(false, "misaligned frame accepted")
} catch { expect(true, "misaligned frame rejected") }

// MARK: Mixer

func makeActiveMixer(rate: Int = 48_000, channels: Int = 2) -> ScreenShareSystemAudioMixer {
    let mixer = ScreenShareSystemAudioMixer(targetSampleRate: rate, targetChannelCount: channels)
    mixer.activate()
    return mixer
}

do {
    let mixer = ScreenShareSystemAudioMixer(targetSampleRate: 48_000, targetChannelCount: 1)
    mixer.push(try ScreenSharePCMFrame(samples: [Float](repeating: 0.5, count: 480), sampleRate: 48_000, channelCount: 1))
    expect(mixer.bufferedFrameCount == 0 && mixer.dequeueMixChunk(frameCount: 480) == nil, "inactive mixer silent")

    let roundTrip = makeActiveMixer(channels: 2)
    let samples: [Float] = [0.1, -0.1, 0.2, -0.2, 0.3, -0.3]
    roundTrip.push(try ScreenSharePCMFrame(samples: samples, sampleRate: 48_000, channelCount: 2))
    expect(roundTrip.dequeueMixChunk(frameCount: 3) == samples, "matching format round trip")

    let pad = makeActiveMixer(channels: 1)
    pad.push(try ScreenSharePCMFrame(samples: [0.5, 0.5], sampleRate: 48_000, channelCount: 1))
    expect(pad.dequeueMixChunk(frameCount: 4) == [0.5, 0.5, 0, 0], "underflow zero pads")
    expect(pad.dequeueMixChunk(frameCount: 4) == nil, "drained mixer returns nil")

    let upmix = makeActiveMixer(channels: 2)
    upmix.push(try ScreenSharePCMFrame(samples: [0.25, -0.5], sampleRate: 48_000, channelCount: 1))
    expect(upmix.dequeueMixChunk(frameCount: 2) == [0.25, 0.25, -0.5, -0.5], "mono upmix")

    let downmix = makeActiveMixer(channels: 1)
    downmix.push(try ScreenSharePCMFrame(samples: [0.2, 0.4, -0.2, -0.4], sampleRate: 48_000, channelCount: 2))
    let downChunk = downmix.dequeueMixChunk(frameCount: 2) ?? []
    expect(downChunk.count == 2 && abs(downChunk[0] - 0.3) < 1e-6 && abs(downChunk[1] + 0.3) < 1e-6, "stereo downmix averages")

    let resample = makeActiveMixer(rate: 48_000, channels: 1)
    resample.push(try ScreenSharePCMFrame(samples: [Float](repeating: 0.5, count: 441), sampleRate: 44_100, channelCount: 1))
    let buffered = resample.bufferedFrameCount
    let resampled = resample.dequeueMixChunk(frameCount: buffered) ?? []
    expect(abs(buffered - 480) <= 1 && resampled.allSatisfy { abs($0 - 0.5) < 1e-5 }, "44.1k→48k resample")

    let ramp = ScreenShareSystemAudioMixer.resampleLinear(
        interleaved: (0..<100).map { Float($0) / 100 },
        channelCount: 1,
        from: 24_000,
        to: 48_000
    )
    expect(ramp.count == 200 && abs(ramp.first! - 0) < 1e-6 && abs(ramp.last! - 0.99) < 1e-6, "ramp resample endpoints")
    expect(zip(ramp, ramp.dropFirst()).allSatisfy { $0 <= $1 + 1e-6 }, "ramp stays monotonic")

    let overflow = makeActiveMixer(rate: 1_000, channels: 2)
    overflow.push(try ScreenSharePCMFrame(samples: [Float](repeating: 0.1, count: 1_800), sampleRate: 1_000, channelCount: 2))
    overflow.push(try ScreenSharePCMFrame(samples: [Float](repeating: 0.9, count: 400), sampleRate: 1_000, channelCount: 2))
    let total = overflow.bufferedFrameCount
    let drained = overflow.dequeueMixChunk(frameCount: total) ?? []
    expect(total <= 500 && drained.count.isMultiple(of: 2) && abs((drained.last ?? 0) - 0.9) < 1e-6, "overflow drops oldest")

    let clear = makeActiveMixer(channels: 1)
    clear.push(try ScreenSharePCMFrame(samples: [Float](repeating: 0.5, count: 480), sampleRate: 48_000, channelCount: 1))
    clear.deactivate()
    expect(clear.bufferedFrameCount == 0 && clear.dequeueMixChunk(frameCount: 480) == nil, "deactivate clears")

    let reconfig = makeActiveMixer(rate: 48_000, channels: 1)
    reconfig.push(try ScreenSharePCMFrame(samples: [Float](repeating: 0.5, count: 480), sampleRate: 48_000, channelCount: 1))
    reconfig.configureTarget(sampleRate: 16_000, channelCount: 1)
    expect(reconfig.bufferedFrameCount == 0, "reconfigure drops stale audio")
} catch {
    expect(false, "mixer block threw \(error)")
}

// MARK: Converter raw decoding

do {
    var int16Data = Data()
    for value in [Int16.max, 0, Int16.min / 2] {
        withUnsafeBytes(of: value.littleEndian) { int16Data.append(contentsOf: $0) }
    }
    let int16Samples = ScreenSharePCMSampleConverter.floatSamples(fromInt16Bytes: int16Data)
    expect(
        int16Samples.count == 3
            && abs(int16Samples[0] - 1) < 1e-4
            && int16Samples[1] == 0
            && abs(int16Samples[2] + 0.5) < 1e-3,
        "int16 byte decode"
    )

    let interleaved = ScreenSharePCMSampleConverter.interleave(planarChannels: [[0.1, 0.2, 0.3], [-0.1, -0.2, -0.3]])
    expect(interleaved == [0.1, -0.1, 0.2, -0.2, 0.3, -0.3], "planar interleave")

    var payload = Data()
    for value in [Int16(16_384), Int16(-16_384), Int16(8_192), Int16(-8_192)] {
        withUnsafeBytes(of: value.littleEndian) { payload.append(contentsOf: $0) }
    }
    let rkFrame = try ScreenSharePCMSampleConverter.pcmFrame(fromReplayKitPayload: payload, sampleRate: 44_100, channelCount: 2)
    expect(rkFrame.frameCount == 2 && abs(rkFrame.samples[0] - 0.5) < 1e-3, "replaykit payload decode")
} catch {
    expect(false, "converter block threw \(error)")
}

// MARK: Converter CMSampleBuffer paths

func makeSampleBuffer(asbd: inout AudioStreamBasicDescription, bytes: Data, frameCount: Int) -> CMSampleBuffer? {
    var formatDescription: CMAudioFormatDescription?
    guard CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault, asbd: &asbd,
        layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
        extensions: nil, formatDescriptionOut: &formatDescription
    ) == noErr, let formatDescription else { return nil }

    var blockBuffer: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
        blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
        offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &blockBuffer
    ) == kCMBlockBufferNoErr, let blockBuffer else { return nil }
    let copied: Bool = bytes.withUnsafeBytes { raw in
        CMBlockBufferReplaceDataBytes(
            with: raw.baseAddress!, blockBuffer: blockBuffer,
            offsetIntoDestination: 0, dataLength: bytes.count
        ) == kCMBlockBufferNoErr
    }
    guard copied else { return nil }

    var sampleBuffer: CMSampleBuffer?
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: CMTimeScale(asbd.mSampleRate)),
        presentationTimeStamp: .zero,
        decodeTimeStamp: .invalid
    )
    guard CMSampleBufferCreate(
        allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, dataReady: true,
        makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDescription,
        sampleCount: frameCount, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer
    ) == noErr else { return nil }
    return sampleBuffer
}

do {
    // Planar Float32 (ScreenCaptureKit default shape).
    let left: [Float] = [0.5, 0.25, -0.5]
    let right: [Float] = [-0.5, -0.25, 0.5]
    var planarASBD = AudioStreamBasicDescription(
        mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
        mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0
    )
    var planarBytes = Data()
    for channel in [left, right] {
        channel.withUnsafeBufferPointer { pointer in
            planarBytes.append(
                UnsafeBufferPointer(
                    start: UnsafeRawPointer(pointer.baseAddress!).assumingMemoryBound(to: UInt8.self),
                    count: channel.count * 4
                )
            )
        }
    }
    if let planarBuffer = makeSampleBuffer(asbd: &planarASBD, bytes: planarBytes, frameCount: 3) {
        let frame = try ScreenSharePCMSampleConverter.pcmFrame(from: planarBuffer)
        expect(
            frame.sampleRate == 48_000 && frame.channelCount == 2 && frame.frameCount == 3
                && abs(frame.samples[0] - 0.5) < 1e-6
                && abs(frame.samples[1] + 0.5) < 1e-6
                && abs(frame.samples[5] - 0.5) < 1e-6,
            "planar float32 CMSampleBuffer"
        )
    } else {
        expect(false, "planar fixture creation")
    }

    // Interleaved Int16.
    var int16ASBD = AudioStreamBasicDescription(
        mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
        mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0
    )
    var int16Bytes = Data()
    for value in [Int16(16_384), Int16(-16_384), Int16(8_192), Int16(-8_192)] {
        withUnsafeBytes(of: value.littleEndian) { int16Bytes.append(contentsOf: $0) }
    }
    if let int16Buffer = makeSampleBuffer(asbd: &int16ASBD, bytes: int16Bytes, frameCount: 2) {
        let frame = try ScreenSharePCMSampleConverter.pcmFrame(from: int16Buffer)
        expect(
            frame.sampleRate == 44_100 && frame.channelCount == 2 && frame.frameCount == 2
                && abs(frame.samples[0] - 0.5) < 1e-3
                && abs(frame.samples[3] + 0.25) < 1e-3,
            "interleaved int16 CMSampleBuffer"
        )
    } else {
        expect(false, "int16 fixture creation")
    }
} catch {
    expect(false, "CMSampleBuffer block threw \(error)")
}

// MARK: WebRTC-facing pieces (compile-time conformance + mixer plumbing)

do {
    let processor = ScreenShareSystemAudioCapturePostProcessor()
    processor.audioProcessingInitialize(sampleRate: 48_000, channels: 1)
    let egress = WebRTCScreenShareSystemAudioEgress(processor: processor)
    egress.activate()
    expect(processor.mixer.isActive, "egress activates processor mixer")
    egress.push(try ScreenSharePCMFrame(samples: [Float](repeating: 0.25, count: 480), sampleRate: 48_000, channelCount: 1))
    expect(processor.mixer.bufferedFrameCount == 480, "egress pushes into mixer")
    egress.deactivate()
    expect(!processor.mixer.isActive && processor.mixer.bufferedFrameCount == 0, "egress deactivate clears mixer")

    processor.mixer.activate()
    processor.mixer.push(try ScreenSharePCMFrame(samples: [Float](repeating: 0.5, count: 480), sampleRate: 48_000, channelCount: 1))
    processor.audioProcessingRelease()
    expect(!processor.mixer.isActive, "processor release deactivates mixer")
} catch {
    expect(false, "processor block threw \(error)")
}

if failures > 0 {
    print("\(failures) FAILURES")
    exit(1)
}
print("ALL HARNESS CHECKS PASSED")
