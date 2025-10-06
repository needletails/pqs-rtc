//
//  RTCSession+State.swift
//  needle-tail-rtc
//
//  Created by Cole M on 9/11/24.
//
//  Copyright (c) 2025 NeedleTails Organization.
//
//  This project is proprietary and confidential.
//
//  All rights reserved. Unauthorized copying, distribution, or use
//  of this software is strictly prohibited.
//
//  This file is part of the NeedleTailRTC SDK, which provides
//  VoIP Capabilities
//
#if !os(Android)
import WebRTC
#endif
import NeedleTailLogger

extension RTCSession {
    
    func handleState(stateStream: AsyncStream<CallStateMachine.State>) async throws {
        logger.log(level: .debug, message: "WILL HANDLE CALL STATE")
        for await state in stateStream {
            logger.log(level: .debug, message: "CALL STATE: \(state)")
            switch state {
            case CallStateMachine.State.waiting:
                break
            case CallStateMachine.State.ready:
                break
            case CallStateMachine.State.connecting(_, let currentCall):
                await getDelegate()?.updateMetadata(for: currentCall, callState: state)
            case CallStateMachine.State.connected(let callDirection, let currentCall):
#if os(macOS)
                await stopRingtone()
#endif
                switch callDirection {
                case CallStateMachine.CallDirection.inbound(_):
                    break
                case CallStateMachine.CallDirection.outbound(let type):
#if os(iOS)
                    try await setAudioMode(mode: type == .video ? .videoChat : .voiceChat)
#endif
                }
                await getDelegate()?.updateMetadata(for: currentCall, callState: state)
            case CallStateMachine.State.held(_, let currentCall):
                await getDelegate()?.updateMetadata(for: currentCall, callState: state)
                //Need to feed id
                await getDelegate()?.sendHoldCallMessage(to: currentCall)
            case CallStateMachine.State.ended(_, let currentCall):
#if os(macOS)
                await stopRingtone()
#endif
                await getDelegate()?.updateMetadata(for: currentCall, callState: state)
                await finishEndConnection(currentCall: currentCall)
            case CallStateMachine.State.failed(let callDirection, let currentCall, let error):
#if os(macOS)
                await stopRingtone()
#endif
                let endState: CallStateMachine.EndState = error == "PeerConnection Failed" ? (callDirection == CallStateMachine.CallDirection.inbound(CallStateMachine.CallType.video) || callDirection == CallStateMachine.CallDirection.inbound(CallStateMachine.CallType.voice) ? CallStateMachine.EndState.partnerInitiatedUnanswered : CallStateMachine.EndState.userInitiatedUnanswered) : CallStateMachine.EndState.failed
                try? await getDelegate()?.invokeEnd(call: currentCall, endState: endState)
                await getDelegate()?.updateMetadata(for: currentCall, callState: CallStateMachine.State.ended(endState, currentCall))
                await finishEndConnection(currentCall: currentCall)
            case CallStateMachine.State.receivedVideoUpgrade, CallStateMachine.State.receivedVoiceDowngrade:
                break
            case CallStateMachine.State.callAnsweredAuxDevice(let currentCall):
#if os(macOS)
                await stopRingtone()
#endif
                await getDelegate()?.updateMetadata(for: currentCall, callState: state)
                await finishEndConnection(currentCall: currentCall)
            }
        }
    }
    
#if os(macOS)
    public func startRingtone() async {
        if let url = Bundle.main.url(forResource: "ringtone", withExtension: "mp3") {
            do {
                audioPlayer = try AVAudioPlayer(contentsOf: url)
                audioPlayer?.volume = 0.5
                audioPlayer?.prepareToPlay()
                audioPlayer?.play()
            } catch {
                logger.log(level: .error, message: "Error initializing player: \(error.localizedDescription)")
            }
        }
    }
    
    public func stopRingtone() async {
        if audioPlayer?.isPlaying == true {
            audioPlayer?.stop()
        }
    }
#endif
    
    /// Safely ends a connection with proper cleanup and error handling
    /// - Parameter currentCall: The call to end
    func finishEndConnection(currentCall: Call) async {
        logger.log(level: .info, message: "Finishing connection for call: \(currentCall.id)")
        
        func cleanup(connection: RTCConnection) {
#if os(Android)
            Self.rtcClient.close()
#else
            connection.peerConnection.delegate = nil
            connection.peerConnection.close()
#endif
        }
        
        // Close peer connection if found
        if let connection = await connectionManager.findConnection(with: currentCall.sharedCommunicationId) {
            cleanup(connection: connection)
            logger.log(level: .debug, message: "Closed peer connection for call: \(currentCall.id)")
        } else {
            // Fallback to last connection if specific connection not found
            if let lastConnection = await connectionManager.findAllConnections().last {
                cleanup(connection: lastConnection)
                logger.log(level: .debug, message: "Closed last peer connection as fallback")
            } else {
                logger.log(level: .warning, message: "No connections found to close for call: \(currentCall.id)")
            }
        }
        
        // Remove connection from manager
        await connectionManager.removeConnection(with: currentCall.sharedCommunicationId)
        
        // Reset call state
        await self.callState.resetState()
        
        // Reset connection state
        setPcState(RTCSession.PeerConnectionState.none)
        setReadyForCandidates(false)
        
        // Clean up candidate consumer
        await inboundCandidateConsumer.removeAll()
        
        // Reset counters and flags
        setNotRunning(true)
        setLastId(0)
        setIceId(0)
        
        // Cancel and cleanup tasks
        getStateTask()?.cancel()
        setStateTask(nil)
        
        logger.log(level: .info, message: "Successfully finished connection for call: \(currentCall.id)")
    }
}
import NeedleTailAsyncSequence

extension NeedleTailAsyncConsumer {
    
    func removeAll() async {
        deque.removeAll()
    }
}
