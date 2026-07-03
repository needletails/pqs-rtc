//
//  ScreenShareSystemAudioCapturePostProcessor.swift
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

#if canImport(WebRTC) && !os(Android)
import Foundation
import NeedleTailLogger
import WebRTC

/// Mixes buffered screen-share system audio into the outbound microphone
/// capture path.
///
/// Installed once as the `capturePostProcessingDelegate` of the
/// `RTCDefaultAudioProcessingModule` used by `RTCSession.factory`. It runs on
/// WebRTC's capture thread for every 10 ms capture buffer; when the mixer is
/// inactive or empty it returns without touching the buffer, so normal call
/// audio is completely unaffected outside of an active system-audio share.
final class ScreenShareSystemAudioCapturePostProcessor: NSObject, RTCAudioCustomProcessingDelegate, @unchecked Sendable {

    let mixer = ScreenShareSystemAudioMixer()
    private let logger = NeedleTailLogger("[ScreenShareSystemAudio]")
    private let stateLock = NSLock()
    /// Last format reported by WebRTC's capture post-processing hook.
    private var captureSampleRate = ScreenShareSystemAudioContract.captureSampleRate
    private var captureChannelCount = 1
    /// When true, mic samples are zeroed before mixing so remotes hear only
    /// system audio while the outbound audio track stays enabled for RTP.
    private var suppressMicCapture = false
    // One-shot diagnostics: the capture post-processing hook lives inside the WebRTC
    // audio pipeline and fails silently if the APM wiring regresses. These prove on a
    // single device run whether the delegate is invoked and whether mixing happened.
    private var loggedInitialize = false
    private var loggedFirstActiveProcess = false
    private var loggedFirstChunkProcess = false
    private var loggedFirstNonSilentChunkProcess = false
    private var silentChunkProcessCount = 0

    func setSuppressMicCapture(_ suppress: Bool) {
        stateLock.withLock {
            suppressMicCapture = suppress
            if suppress {
                loggedFirstActiveProcess = false
                loggedFirstChunkProcess = false
                loggedFirstNonSilentChunkProcess = false
                silentChunkProcessCount = 0
            }
        }
    }

    /// Seeds mixer format before WebRTC invokes `audioProcessingInitialize`.
    ///
    /// Uses the last known WebRTC capture format (mono on macOS ADM) rather than
    /// ScreenCaptureKit's stereo capture format so mixed chunks align with the
    /// outbound mic track.
    func prepareForSystemAudioShare() {
        let (sampleRate, channels) = stateLock.withLock {
            (captureSampleRate, captureChannelCount)
        }
        mixer.configureTarget(sampleRate: sampleRate, channelCount: channels)
    }

    func audioProcessingInitialize(sampleRate sampleRateHz: Int, channels: Int) {
        let shouldLog = stateLock.withLock {
            captureSampleRate = sampleRateHz
            captureChannelCount = channels
            if loggedInitialize { return false }
            loggedInitialize = true
            return true
        }
        if shouldLog {
            logger.log(
                level: .info,
                message: "Capture post-processing initialized sampleRate=\(sampleRateHz) channels=\(channels)"
            )
        }
        mixer.configureTarget(sampleRate: sampleRateHz, channelCount: channels)
    }

    func audioProcessingProcess(audioBuffer: RTCAudioBuffer) {
        let frames = audioBuffer.frames
        let channels = audioBuffer.channels
        processCaptureAudio(frames: frames, channels: channels) { channel in
            audioBuffer.rawBuffer(forChannel: channel)
        }
    }

    func processCaptureAudio(
        frames: Int,
        channels: Int,
        rawBufferForChannel: (Int) -> UnsafeMutablePointer<Float>
    ) {
        guard frames > 0, channels > 0 else { return }

        let suppressMic = stateLock.withLock { suppressMicCapture }
        let chunk = mixer.dequeueMixChunk(frameCount: frames)
        guard suppressMic || chunk != nil else { return }

        let (shouldLogFirstActive, shouldLogFirstChunk, nonSilentLog) = stateLock.withLock {
            let logActive = !loggedFirstActiveProcess
            if logActive { loggedFirstActiveProcess = true }

            let logChunk = chunk != nil && !loggedFirstChunkProcess
            if logChunk { loggedFirstChunkProcess = true }

            let logNonSilent: (shouldLog: Bool, silentChunksBefore: Int, silenceWarningChunkCount: Int?)
            if let chunk, Self.chunkContainsMeaningfulAudio(chunk) {
                if loggedFirstNonSilentChunkProcess {
                    logNonSilent = (false, silentChunkProcessCount, nil)
                } else {
                    loggedFirstNonSilentChunkProcess = true
                    logNonSilent = (true, silentChunkProcessCount, nil)
                }
            } else if chunk != nil && !loggedFirstNonSilentChunkProcess {
                silentChunkProcessCount += 1
                let shouldWarn = silentChunkProcessCount == 100 || silentChunkProcessCount == 500
                logNonSilent = (false, silentChunkProcessCount, shouldWarn ? silentChunkProcessCount : nil)
            } else {
                logNonSilent = (false, silentChunkProcessCount, nil)
            }

            return (logActive, logChunk, logNonSilent)
        }
        if shouldLogFirstActive {
            logger.log(
                level: .info,
                message: "Mixing system audio into capture path suppressMic=\(suppressMic) hasChunk=\(chunk != nil) frames=\(frames) channels=\(channels)"
            )
        }
        if shouldLogFirstChunk {
            let peak = chunk?.reduce(Float(0)) { max($0, abs($1)) } ?? 0
            let rms: Float = {
                guard let chunk, !chunk.isEmpty else { return 0 }
                let sumSquares = chunk.reduce(Double(0)) { partial, sample in
                    let value = Double(sample)
                    return partial + value * value
                }
                return Float((sumSquares / Double(chunk.count)).squareRoot())
            }()
            logger.log(
                level: .info,
                message: "First system-audio chunk mixed into capture path frames=\(frames) channels=\(channels) peak=\(peak) rms=\(rms)"
            )
        }
        if nonSilentLog.shouldLog {
            let (peak, rms) = Self.levels(for: chunk ?? [])
            logger.log(
                level: .info,
                message: "First non-silent system-audio chunk mixed into capture path frames=\(frames) channels=\(channels) peak=\(peak) rms=\(rms) silentChunksBefore=\(nonSilentLog.silentChunksBefore)"
            )
        }
        if let silenceWarningChunkCount = nonSilentLog.silenceWarningChunkCount {
            let (peak, rms) = Self.levels(for: chunk ?? [])
            logger.log(
                level: .warning,
                message: "System-audio chunks still silent in capture path chunks=\(silenceWarningChunkCount) lastPeak=\(peak) lastRms=\(rms)"
            )
        }

        // WebRTC AudioBuffer floats use int16 full-scale range.
        let scale = ScreenShareSystemAudioContract.webrtcFloatS16FullScale
        let limit = scale - 1
        let gain = ScreenShareSystemAudioContract.systemAudioMixGain

        for channel in 0..<channels {
            let channelBuffer = rawBufferForChannel(channel)
            for frame in 0..<frames {
                if suppressMic {
                    channelBuffer[frame] = 0
                }
                if let chunk {
                    let mixSample = chunk[frame * channels + channel] * scale * gain
                    let mixed = channelBuffer[frame] + mixSample
                    channelBuffer[frame] = min(max(mixed, -scale), limit)
                }
            }
        }
    }

    private static func chunkContainsMeaningfulAudio(_ chunk: [Float]) -> Bool {
        let (peak, rms) = levels(for: chunk)
        return peak > 0.0001 || rms > 0.00001
    }

    private static func levels(for chunk: [Float]) -> (peak: Float, rms: Float) {
        let peak = chunk.reduce(Float(0)) { max($0, abs($1)) }
        guard !chunk.isEmpty else { return (peak, 0) }
        let sumSquares = chunk.reduce(Double(0)) { partial, sample in
            let value = Double(sample)
            return partial + value * value
        }
        return (peak, Float((sumSquares / Double(chunk.count)).squareRoot()))
    }

    func audioProcessingRelease() {
        setSuppressMicCapture(false)
        mixer.deactivate()
    }
}
#endif
