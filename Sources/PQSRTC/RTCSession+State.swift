//
//  RTCSession+State.swift
//  pqs-rtc
//
//  Created by Cole M on 12/4/25.
//
//  Copyright (c) 2025 NeedleTails Organization.
//
//  This project is licensed under the MIT License.
//
//  See the LICENSE file for more information.
//
//
//  This file is part of the PQSRTC SDK, which provides
//  Frame Encrypted VoIP Capabilities
//

#if !os(Android)
import WebRTC
#endif
import NeedleTailLogger

extension RTCSession {
    func handleState(stateStream: AsyncStream<CallStateMachine.State>) async throws {
        for await state in stateStream {
            switch state {
            case CallStateMachine.State.waiting:
                break
            case CallStateMachine.State.ready:
                break
            case CallStateMachine.State.connecting(_, _):
                break
            case CallStateMachine.State.connected(let callDirection, _):
#if os(macOS)
                await stopRingtone()
#endif
                // Ensure audio session is fully configured and enabled on iOS
#if os(iOS)
                do {
                    let mode: AVAudioSession.Mode
                    switch callDirection {
                    case .inbound(let type), .outbound(let type):
                        switch type {
                        case .voice:
                            mode = .voiceChat
                        case .video:
                            mode = .videoChat
                        }
                    }

                    // IMPORTANT (audio engine stability):
                    // CallKit's `provider:didActivate:` (relayed by the host app via
                    // `setExternalAudioSession()` + `setAudioMode(...)` + `activateAudioSession(...)`)
                    // already configures and activates the AVAudioSession before we
                    // reach `.connected`. Re-applying `setCategory` / `setMode` /
                    // `overrideOutputAudioPort` here used to race with WebRTC's
                    // `AURemoteIO` start sequence, producing:
                    //
                    // Host apps integrating inbound 1:1 server-SFU: defer SFU media bootstrap until
                    // after CallKit audio activation. DocC (PQSRTC): "Host app integration: CallKit
                    // and server SFU (iOS)" in Sources/PQSRTC/PQSRTC.docc/; app pointer:
                    // nudge-app Sources/Nudge/Documentation.docc/OneToOneSfuCallKitMedia.md
                    //
                    // Re-applying mode here (when the session was already active) produced:
                    //   `ATAudioSessionPropertyManager.mm: FAILED to set property … -50`
                    //   `AURemoteIO StartIO failed (kAudioUnitErr_CannotDoInCurrentContext)`
                    // …which silently kills audio in both directions while video
                    // continues to flow.
                    //
                    // Only reconfigure the session when it isn't active yet (e.g. unit
                    // tests, custom integrations that don't go through CallKit). When
                    // the session is already active, just make sure WebRTC's playout/
                    // recording is enabled so audio actually starts moving.
                    if !audioSession.isActive {
                        try setAudioMode(mode: mode)
                    } else {
                        logger.log(level: .info, message: "Audio session already active on .connected; skipping redundant setAudioMode to avoid AURemoteIO start race")
                    }
                    // Explicitly enable WebRTC audio playout/recording
                    setAudio(true)
                } catch {
                    logger.log(level: .error, message: "Failed to configure iOS audio session on connected state: \(error)")
                }
#else
                switch callDirection {
                case CallStateMachine.CallDirection.inbound(_):
                    break
                case CallStateMachine.CallDirection.outbound(_):
                    break
                }
#endif
            case CallStateMachine.State.held(_, _):
                break
            case CallStateMachine.State.ended(_, _):
#if os(macOS)
                await stopRingtone()
#endif
#if os(iOS)
                // Disable audio when the call has fully ended
                setAudio(false)
#endif
            case CallStateMachine.State.failed(let callDirection, let currentCall, let error):
#if os(macOS)
                await stopRingtone()
#endif
#if os(iOS)
                // Also disable audio on failure to avoid leaving the session active
                setAudio(false)
#endif
                let endState: CallStateMachine.EndState = error == "PeerConnection Failed" ? (callDirection == CallStateMachine.CallDirection.inbound(CallStateMachine.CallType.video) || callDirection == CallStateMachine.CallDirection.inbound(CallStateMachine.CallType.voice) ? CallStateMachine.EndState.partnerInitiatedUnanswered : CallStateMachine.EndState.userInitiatedUnanswered) : CallStateMachine.EndState.failed
                if let delegate {
                    try? await delegate.didEnd(call: currentCall, endState: endState)
                } else {
                    logger.log(level: .warning, message: "RTCTransportEvents delegate not set; cannot send didEnd for call \(currentCall.sharedCommunicationId)")
                }
                await finishEndConnection(currentCall: currentCall)
            case CallStateMachine.State.callAnsweredAuxDevice(let currentCall):
#if os(macOS)
                await stopRingtone()
#endif
#if os(iOS)
                setAudio(false)
#endif
                await finishEndConnection(currentCall: currentCall)
            }
        }
    }
}
