//
//  ScreenSharePCMFrame.swift
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

import Foundation

/// One block of captured system audio, normalized for the egress pipeline.
///
/// Samples are interleaved Float32 in the range [-1, 1]
/// (`L0 R0 L1 R1 …` for stereo).
public struct ScreenSharePCMFrame: Sendable, Equatable {
    public let samples: [Float]
    public let sampleRate: Int
    public let channelCount: Int

    public init(samples: [Float], sampleRate: Int, channelCount: Int) throws {
        guard sampleRate > 0 else {
            throw ScreenShareSystemAudioError.invalidSampleRate(sampleRate)
        }
        guard channelCount > 0 else {
            throw ScreenShareSystemAudioError.invalidChannelCount(channelCount)
        }
        guard !samples.isEmpty, samples.count.isMultiple(of: channelCount) else {
            throw ScreenShareSystemAudioError.invalidSampleCount(
                samples: samples.count,
                channels: channelCount
            )
        }
        self.samples = samples
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    /// Samples per channel.
    public var frameCount: Int {
        samples.count / channelCount
    }

    /// Duration represented by this frame.
    public var durationSeconds: Double {
        Double(frameCount) / Double(sampleRate)
    }

    var peakMagnitude: Float {
        samples.reduce(Float(0)) { max($0, abs($1)) }
    }

    var rmsMagnitude: Float {
        guard !samples.isEmpty else { return 0 }
        let sumSquares = samples.reduce(Double(0)) { partial, sample in
            let value = Double(sample)
            return partial + value * value
        }
        return Float((sumSquares / Double(samples.count)).squareRoot())
    }

    var containsMeaningfulAudio: Bool {
        peakMagnitude > 0.0001 || rmsMagnitude > 0.00001
    }
}

/// Failures in the screen-share system-audio pipeline.
public enum ScreenShareSystemAudioError: Error, Equatable, Sendable {
    case invalidSampleRate(Int)
    case invalidChannelCount(Int)
    case invalidSampleCount(samples: Int, channels: Int)
    case emptyAudioBuffer
    case unsupportedAudioFormat(String)
}
