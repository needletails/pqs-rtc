#if os(iOS) || os(macOS)
import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import PQSRTC

@Suite(.serialized)
struct ScreenSharePCMSampleConverterTests {

    // MARK: - Raw sample decoding

    @Test("big-endian Int16 wire bytes decode incorrectly as little-endian")
    func bigEndianInt16MismatchDocumentsReplayKitBug() {
        // ReplayKit .audioApp buffers are 16-bit big-endian on iOS. If the broadcast
        // extension forwards them raw, this is what the app-side converter would hear.
        var data = Data()
        for value in [Int16(16_384), Int16(-16_384)] {
            withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
        }
        let samples = ScreenSharePCMSampleConverter.floatSamples(fromInt16Bytes: data)
        #expect(samples.count == 2)
        #expect(abs(samples[0] - 0.5) > 0.4, "big-endian bytes must not decode as 0.5 when read as LE")
    }

    @Test("Int16 bytes decode to normalized floats")
    func int16BytesDecode() {
        var data = Data()
        for value in [Int16.max, 0, Int16.min / 2] {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let samples = ScreenSharePCMSampleConverter.floatSamples(fromInt16Bytes: data)
        #expect(samples.count == 3)
        #expect(abs(samples[0] - 1.0) < 1e-4)
        #expect(samples[1] == 0)
        #expect(abs(samples[2] - (-0.5)) < 1e-3)
    }

    @Test("Float32 bytes decode verbatim")
    func float32BytesDecode() {
        var data = Data()
        for value: Float32 in [0.75, -0.25, 0] {
            withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
        }
        let samples = ScreenSharePCMSampleConverter.floatSamples(fromFloat32Bytes: data)
        #expect(samples == [0.75, -0.25, 0])
    }

    @Test("planar channels interleave L,R order")
    func planarInterleaving() {
        let interleaved = ScreenSharePCMSampleConverter.interleave(
            planarChannels: [[0.1, 0.2, 0.3], [-0.1, -0.2, -0.3]]
        )
        #expect(interleaved == [0.1, -0.1, 0.2, -0.2, 0.3, -0.3])
    }

    @Test("interleave trims to shortest channel")
    func planarInterleavingTrims() {
        let interleaved = ScreenSharePCMSampleConverter.interleave(
            planarChannels: [[0.1, 0.2, 0.3], [-0.1]]
        )
        #expect(interleaved == [0.1, -0.1])
    }

    // MARK: - ReplayKit relay payloads

    @Test("ReplayKit Int16 payload converts with packet metadata")
    func replayKitPayloadConverts() throws {
        var payload = Data()
        for value in [Int16(16_384), Int16(-16_384), Int16(8_192), Int16(-8_192)] {
            withUnsafeBytes(of: value.littleEndian) { payload.append(contentsOf: $0) }
        }
        let frame = try ScreenSharePCMSampleConverter.pcmFrame(
            fromReplayKitPayload: payload,
            sampleRate: 44_100,
            channelCount: 2
        )
        #expect(frame.sampleRate == 44_100)
        #expect(frame.channelCount == 2)
        #expect(frame.frameCount == 2)
        #expect(abs(frame.samples[0] - 0.5) < 1e-3)
        #expect(abs(frame.samples[1] - (-0.5)) < 1e-3)
    }

    @Test("ReplayKit payload trims trailing partial frame")
    func replayKitPayloadTrimsPartialFrame() throws {
        var payload = Data()
        for value in [Int16(100), Int16(200), Int16(300)] {
            withUnsafeBytes(of: value.littleEndian) { payload.append(contentsOf: $0) }
        }
        // 3 samples over 2 channels → 1 whole frame.
        let frame = try ScreenSharePCMSampleConverter.pcmFrame(
            fromReplayKitPayload: payload,
            sampleRate: 48_000,
            channelCount: 2
        )
        #expect(frame.frameCount == 1)
    }

    @Test("empty ReplayKit payload is rejected")
    func emptyReplayKitPayloadRejected() {
        #expect(throws: ScreenShareSystemAudioError.self) {
            try ScreenSharePCMSampleConverter.pcmFrame(
                fromReplayKitPayload: Data(),
                sampleRate: 48_000,
                channelCount: 2
            )
        }
    }

    // MARK: - CMSampleBuffer (ScreenCaptureKit shape)

    @Test("planar Float32 CMSampleBuffer converts (SCK default shape)")
    func planarFloat32SampleBufferConverts() throws {
        let left: [Float] = [0.5, 0.25, -0.5]
        let right: [Float] = [-0.5, -0.25, 0.5]
        let sampleBuffer = try Self.makeSampleBuffer(
            planarFloatChannels: [left, right],
            sampleRate: 48_000
        )

        let frame = try ScreenSharePCMSampleConverter.pcmFrame(from: sampleBuffer)
        #expect(frame.sampleRate == 48_000)
        #expect(frame.channelCount == 2)
        #expect(frame.frameCount == 3)
        #expect(abs(frame.samples[0] - 0.5) < 1e-6)
        #expect(abs(frame.samples[1] - (-0.5)) < 1e-6)
        #expect(abs(frame.samples[4] - (-0.5)) < 1e-6)
        #expect(abs(frame.samples[5] - 0.5) < 1e-6)
    }

    @Test("interleaved Int16 CMSampleBuffer converts")
    func interleavedInt16SampleBufferConverts() throws {
        let interleaved: [Int16] = [16_384, -16_384, 8_192, -8_192]
        let sampleBuffer = try Self.makeSampleBuffer(
            interleavedInt16: interleaved,
            channelCount: 2,
            sampleRate: 44_100
        )

        let frame = try ScreenSharePCMSampleConverter.pcmFrame(from: sampleBuffer)
        #expect(frame.sampleRate == 44_100)
        #expect(frame.channelCount == 2)
        #expect(frame.frameCount == 2)
        #expect(abs(frame.samples[0] - 0.5) < 1e-3)
        #expect(abs(frame.samples[3] - (-0.25)) < 1e-3)
    }

    // MARK: - Fixture builders

    static func makeSampleBuffer(
        planarFloatChannels channels: [[Float]],
        sampleRate: Double
    ) throws -> CMSampleBuffer {
        let channelCount = channels.count
        let frameCount = channels[0].count
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        // Planar layout: all of channel 0, then all of channel 1.
        var bytes = Data()
        for channel in channels {
            channel.withUnsafeBufferPointer { pointer in
                bytes.append(UnsafeBufferPointer(
                    start: UnsafeRawPointer(pointer.baseAddress!).assumingMemoryBound(to: UInt8.self),
                    count: frameCount * 4
                ))
            }
        }
        return try makeSampleBuffer(
            asbd: &asbd,
            bytes: bytes,
            frameCount: frameCount
        )
    }

    static func makeSampleBuffer(
        interleavedInt16 samples: [Int16],
        channelCount: Int,
        sampleRate: Double
    ) throws -> CMSampleBuffer {
        let bytesPerFrame = UInt32(2 * channelCount)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var bytes = Data()
        for sample in samples {
            withUnsafeBytes(of: sample.littleEndian) { bytes.append(contentsOf: $0) }
        }
        return try makeSampleBuffer(
            asbd: &asbd,
            bytes: bytes,
            frameCount: samples.count / channelCount
        )
    }

    private static func makeSampleBuffer(
        asbd: inout AudioStreamBasicDescription,
        bytes: Data,
        frameCount: Int
    ) throws -> CMSampleBuffer {
        var formatDescription: CMAudioFormatDescription?
        var status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let formatDescription else {
            throw ScreenShareSystemAudioError.unsupportedAudioFormat("fixture format status=\(status)")
        }

        var blockBuffer: CMBlockBuffer?
        status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: bytes.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: bytes.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            throw ScreenShareSystemAudioError.unsupportedAudioFormat("fixture block status=\(status)")
        }
        try bytes.withUnsafeBytes { rawBuffer in
            let copyStatus = CMBlockBufferReplaceDataBytes(
                with: rawBuffer.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: bytes.count
            )
            guard copyStatus == kCMBlockBufferNoErr else {
                throw ScreenShareSystemAudioError.unsupportedAudioFormat("fixture copy status=\(copyStatus)")
            }
        }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(asbd.mSampleRate)),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw ScreenShareSystemAudioError.unsupportedAudioFormat("fixture sample status=\(status)")
        }
        return sampleBuffer
    }
}
#endif
