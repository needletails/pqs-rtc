//
//  ScreenSharePCMSampleConverter.swift
//  pqs-rtc
//
//  Copyright (c) 2026 NeedleTails Organization.
//
//  This project is licensed under the MIT License.
//
//  See the LICENSE file for more information.
//
//
//  This file is part of the PQSRTC SDK, which provides
//  Frame Encrypted VoIP Capabilities
//

#if os(iOS) || os(macOS)
import CoreMedia
import Foundation

/// Converts captured audio (ScreenCaptureKit `CMSampleBuffer`s, ReplayKit
/// relay payloads) into normalized `ScreenSharePCMFrame`s.
enum ScreenSharePCMSampleConverter {

    // MARK: - CMSampleBuffer (ScreenCaptureKit)

    /// Supports Float32 and Int16 LPCM, interleaved or planar
    /// (ScreenCaptureKit delivers planar Float32 by default).
    static func pcmFrame(from sampleBuffer: CMSampleBuffer) throws -> ScreenSharePCMFrame {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee
        else {
            throw ScreenShareSystemAudioError.unsupportedAudioFormat("missing audio format description")
        }
        guard asbd.mFormatID == kAudioFormatLinearPCM else {
            throw ScreenShareSystemAudioError.unsupportedAudioFormat("non-LPCM formatID=\(asbd.mFormatID)")
        }

        let sampleRate = Int(asbd.mSampleRate)
        let channelCount = Int(asbd.mChannelsPerFrame)
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isPlanar = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let bitsPerChannel = Int(asbd.mBitsPerChannel)

        let channelBuffers = try rawChannelBuffers(from: sampleBuffer)

        let perChannelSamples: [[Float]]
        switch (isFloat, bitsPerChannel) {
        case (true, 32):
            perChannelSamples = channelBuffers.map { floatSamples(fromFloat32Bytes: $0) }
        case (false, 16):
            perChannelSamples = channelBuffers.map { floatSamples(fromInt16Bytes: $0) }
        default:
            throw ScreenShareSystemAudioError.unsupportedAudioFormat(
                "LPCM float=\(isFloat) bits=\(bitsPerChannel)"
            )
        }

        let interleaved: [Float]
        if isPlanar {
            interleaved = interleave(planarChannels: perChannelSamples)
        } else {
            interleaved = perChannelSamples.first ?? []
        }
        guard !interleaved.isEmpty else {
            throw ScreenShareSystemAudioError.emptyAudioBuffer
        }
        return try ScreenSharePCMFrame(
            samples: interleaved,
            sampleRate: sampleRate,
            channelCount: channelCount
        )
    }

    // MARK: - ReplayKit relay payload

    /// The broadcast extension relays Int16 little-endian interleaved LPCM; it
    /// canonicalizes ReplayKit's native formats (notably 16-bit big-endian app
    /// audio) before sending (see `BroadcastHandler.audioPayload`).
    static func pcmFrame(
        fromReplayKitPayload payload: Data,
        sampleRate: Int,
        channelCount: Int
    ) throws -> ScreenSharePCMFrame {
        guard !payload.isEmpty else {
            throw ScreenShareSystemAudioError.emptyAudioBuffer
        }
        let samples = floatSamples(fromInt16Bytes: payload)
        guard !samples.isEmpty else {
            throw ScreenShareSystemAudioError.emptyAudioBuffer
        }
        // Defend against truncated relay payloads: trim to whole frames.
        let usable = samples.count - samples.count % max(1, channelCount)
        guard usable > 0 else {
            throw ScreenShareSystemAudioError.invalidSampleCount(
                samples: samples.count,
                channels: channelCount
            )
        }
        return try ScreenSharePCMFrame(
            samples: Array(samples.prefix(usable)),
            sampleRate: sampleRate,
            channelCount: channelCount
        )
    }

    // MARK: - Sample decoding

    static func floatSamples(fromInt16Bytes data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Int16>.size
        guard count > 0 else { return [] }
        var samples = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { rawBuffer in
            let int16Buffer = rawBuffer.bindMemory(to: Int16.self)
            for index in 0..<count {
                samples[index] = Float(Int16(littleEndian: int16Buffer[index])) / Float(Int16.max)
            }
        }
        return samples
    }

    static func floatSamples(fromFloat32Bytes data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float32>.size
        guard count > 0 else { return [] }
        var samples = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { rawBuffer in
            let floatBuffer = rawBuffer.bindMemory(to: Float32.self)
            for index in 0..<count {
                samples[index] = normalizeFloatSample(floatBuffer[index])
            }
        }
        return samples
    }

    /// ScreenCaptureKit occasionally delivers float LPCM outside [-1, 1].
    /// Clamp before mixing into WebRTC's int16-scaled capture path.
    static func normalizeFloatSample(_ sample: Float) -> Float {
        guard sample.isFinite else { return 0 }
        if sample > 1 { return 1 }
        if sample < -1 { return -1 }
        return sample
    }

    static func interleave(planarChannels: [[Float]]) -> [Float] {
        guard let frameCount = planarChannels.map(\.count).min(), frameCount > 0 else { return [] }
        let channelCount = planarChannels.count
        var interleaved = [Float](repeating: 0, count: frameCount * channelCount)
        for channel in 0..<channelCount {
            let channelSamples = planarChannels[channel]
            for frame in 0..<frameCount {
                interleaved[frame * channelCount + channel] = channelSamples[frame]
            }
        }
        return interleaved
    }

    // MARK: - CMSampleBuffer plumbing

    private static func rawChannelBuffers(from sampleBuffer: CMSampleBuffer) throws -> [Data] {
        var blockBuffer: CMBlockBuffer?
        var bufferListSize = 0

        // First query the required AudioBufferList size (planar buffers carry
        // one AudioBuffer per channel).
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: nil
        )
        guard bufferListSize >= MemoryLayout<AudioBufferList>.size else {
            throw ScreenShareSystemAudioError.emptyAudioBuffer
        }

        let listPointer = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { listPointer.deallocate() }
        let audioBufferListPointer = listPointer.assumingMemoryBound(to: AudioBufferList.self)

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferListPointer,
            bufferListSize: bufferListSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else {
            throw ScreenShareSystemAudioError.unsupportedAudioFormat("audio buffer list status=\(status)")
        }

        // Copy out of the block-buffer-backed pointers before it goes away.
        let channelData: [Data] = withExtendedLifetime(blockBuffer) {
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferListPointer)
            var collected: [Data] = []
            for audioBuffer in buffers {
                guard let dataPointer = audioBuffer.mData, audioBuffer.mDataByteSize > 0 else { continue }
                collected.append(Data(bytes: dataPointer, count: Int(audioBuffer.mDataByteSize)))
            }
            return collected
        }
        guard !channelData.isEmpty else {
            throw ScreenShareSystemAudioError.emptyAudioBuffer
        }
        return channelData
    }
}
#endif
