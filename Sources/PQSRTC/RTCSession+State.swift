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
                //                await delegate.updateMetadata(for: currentCall, callState: state)
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
                    // Configure category/mode and activate the session if needed
                    try setAudioMode(mode: mode)
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
                //                await delegate.updateMetadata(for: currentCall, callState: state)
            case CallStateMachine.State.held(_, _):
                break
                //                await delegate.updateMetadata(for: currentCall, callState: state)
                //Need to feed id
                //                await delegate.sendHoldCallMessage(to: currentCall)
            case CallStateMachine.State.ended(_, _):
#if os(macOS)
                await stopRingtone()
#endif
#if os(iOS)
                // Disable audio when the call has fully ended
                setAudio(false)
#endif
                //                Task { [weak self] in
                //                    guard let self else { return }
                //                    await delegate.updateMetadata(for: currentCall, callState: state)
                //                }
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
                //                await delegate.updateMetadata(for: currentCall, callState: CallStateMachine.State.ended(endState, currentCall))
                await finishEndConnection(currentCall: currentCall)
            case CallStateMachine.State.callAnsweredAuxDevice(let currentCall):
#if os(macOS)
                await stopRingtone()
#endif
#if os(iOS)
                setAudio(false)
#endif
                //                await delegate.updateMetadata(for: currentCall, callState: state)
                await finishEndConnection(currentCall: currentCall)
            }
        }
    }
}
