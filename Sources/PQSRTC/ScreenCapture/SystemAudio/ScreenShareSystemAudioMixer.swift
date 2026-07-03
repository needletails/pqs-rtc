//
//  ScreenShareSystemAudioMixer.swift
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

/// Buffers captured system audio and serves it in capture-pipeline-sized
/// chunks for mixing into the outbound microphone path.
///
/// - `push(_:)` is called from the screen-capture audio queue with frames in
///   any source format; samples are channel-mapped and resampled to the
///   configured target format on entry.
/// - `dequeueMixChunk(frameCount:)` is called from the WebRTC capture thread
///   once per 10 ms processing step and returns interleaved samples at the
///   target format, or `nil` when inactive or empty.
///
/// All state is guarded by a single lock; both call sites only copy data.
final class ScreenShareSystemAudioMixer: @unchecked Sendable {

    private let lock = NSLock()
    private var active = false
    private var targetSampleRate: Int
    private var targetChannelCount: Int
    private var buffered: [Float] = []
    private var droppedSampleCount = 0

    init(
        targetSampleRate: Int = ScreenShareSystemAudioContract.captureSampleRate,
        targetChannelCount: Int = 1
    ) {
        self.targetSampleRate = max(1, targetSampleRate)
        self.targetChannelCount = max(1, targetChannelCount)
    }

    // MARK: - Lifecycle

    /// Reconfigures the output format (from `audioProcessingInitialize`).
    /// Buffered audio at the old format is dropped.
    func configureTarget(sampleRate: Int, channelCount: Int) {
        guard sampleRate > 0, channelCount > 0 else { return }
        lock.withLock {
            guard sampleRate != targetSampleRate || channelCount != targetChannelCount else { return }
            targetSampleRate = sampleRate
            targetChannelCount = channelCount
            buffered.removeAll(keepingCapacity: true)
        }
    }

    func activate() {
        lock.withLock {
            active = true
        }
    }

    /// Stops serving audio and drops anything buffered so no stale system
    /// audio can play after a share ends.
    func deactivate() {
        lock.withLock {
            active = false
            buffered.removeAll(keepingCapacity: false)
            droppedSampleCount = 0
        }
    }

    var isActive: Bool {
        lock.withLock { active }
    }

    /// Buffered samples-per-channel currently awaiting mixing.
    var bufferedFrameCount: Int {
        lock.withLock {
            targetChannelCount > 0 ? buffered.count / targetChannelCount : 0
        }
    }

    // MARK: - Ingress

    /// Converts the frame to the target format and appends it to the buffer.
    /// Ignored while inactive. Oldest samples are dropped beyond the
    /// `ScreenShareSystemAudioContract.maxBufferedMs` cap.
    func push(_ frame: ScreenSharePCMFrame) {
        lock.withLock {
            guard active else { return }

            let converted = Self.convert(
                frame: frame,
                toSampleRate: targetSampleRate,
                channelCount: targetChannelCount
            )
            guard !converted.isEmpty else { return }
            buffered.append(contentsOf: converted)

            let maxSamples = targetSampleRate
                * targetChannelCount
                * ScreenShareSystemAudioContract.maxBufferedMs / 1_000
            if buffered.count > maxSamples {
                let overflow = buffered.count - maxSamples
                // Drop whole frames so channels stay aligned.
                let alignedOverflow = overflow + (targetChannelCount - overflow % targetChannelCount) % targetChannelCount
                buffered.removeFirst(min(alignedOverflow, buffered.count))
                droppedSampleCount += alignedOverflow
            }
        }
    }

    // MARK: - Egress

    /// Returns exactly `frameCount` interleaved target-format samples, or `nil`
    /// when inactive or fewer than `frameCount` frames are buffered.
    ///
    /// Partial frames are not zero-padded: padding mid-buffer causes audible
    /// stutter when ScreenCaptureKit delivery and the 10 ms WebRTC capture step
    /// drift slightly.
    func dequeueMixChunk(frameCount: Int) -> [Float]? {
        guard frameCount > 0 else { return nil }
        return lock.withLock {
            guard active else { return nil }
            let wanted = frameCount * targetChannelCount
            guard buffered.count >= wanted else { return nil }
            let chunk = Array(buffered.prefix(wanted))
            buffered.removeFirst(wanted)
            return chunk
        }
    }

    // MARK: - Format conversion

    /// Channel-maps then linearly resamples one frame to the target format.
    static func convert(
        frame: ScreenSharePCMFrame,
        toSampleRate targetSampleRate: Int,
        channelCount targetChannelCount: Int
    ) -> [Float] {
        let channelMapped = mapChannels(
            samples: frame.samples,
            from: frame.channelCount,
            to: targetChannelCount
        )
        guard frame.sampleRate != targetSampleRate else { return channelMapped }
        return resampleLinear(
            interleaved: channelMapped,
            channelCount: targetChannelCount,
            from: frame.sampleRate,
            to: targetSampleRate
        )
    }

    /// Mono → N duplicates; N → mono averages; otherwise truncate/repeat-last.
    static func mapChannels(samples: [Float], from source: Int, to target: Int) -> [Float] {
        guard source != target, source > 0, target > 0 else { return samples }
        let frames = samples.count / source
        var output = [Float]()
        output.reserveCapacity(frames * target)

        for frameIndex in 0..<frames {
            let base = frameIndex * source
            if target == 1 {
                var sum: Float = 0
                for channel in 0..<source {
                    sum += samples[base + channel]
                }
                output.append(sum / Float(source))
            } else if source == 1 {
                let sample = samples[base]
                output.append(contentsOf: repeatElement(sample, count: target))
            } else {
                for channel in 0..<target {
                    output.append(samples[base + min(channel, source - 1)])
                }
            }
        }
        return output
    }

    /// Linear-interpolation resampler over interleaved samples.
    static func resampleLinear(
        interleaved: [Float],
        channelCount: Int,
        from sourceRate: Int,
        to targetRate: Int
    ) -> [Float] {
        guard sourceRate > 0, targetRate > 0, channelCount > 0 else { return [] }
        guard sourceRate != targetRate else { return interleaved }

        let sourceFrames = interleaved.count / channelCount
        guard sourceFrames > 0 else { return [] }
        let targetFrames = max(1, Int((Double(sourceFrames) * Double(targetRate) / Double(sourceRate)).rounded()))

        var output = [Float](repeating: 0, count: targetFrames * channelCount)
        let step = Double(sourceFrames - 1) / Double(max(1, targetFrames - 1))

        for targetFrame in 0..<targetFrames {
            let sourcePosition = Double(targetFrame) * step
            let lowerFrame = min(sourceFrames - 1, Int(sourcePosition))
            let upperFrame = min(sourceFrames - 1, lowerFrame + 1)
            let fraction = Float(sourcePosition - Double(lowerFrame))

            for channel in 0..<channelCount {
                let lower = interleaved[lowerFrame * channelCount + channel]
                let upper = interleaved[upperFrame * channelCount + channel]
                output[targetFrame * channelCount + channel] = lower + (upper - lower) * fraction
            }
        }
        return output
    }
}
