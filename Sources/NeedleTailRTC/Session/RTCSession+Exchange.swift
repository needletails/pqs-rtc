//
//  RTCSession+Exchange.swift
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
import Foundation
import NeedleTailAsyncSequence
import NeedleTailLogger
#if !os(Android)
@preconcurrency import WebRTC
#endif
#if SKIP
import org.webrtc.__
#endif

extension RTCSession {
    
    func modifySDP(sdp: String, hasVideo: Bool = false) async -> String {
        // Helper function to replace receive/sendonly/inactive with sendrecv in a given line.
        func sendAndReceiveMedia(in line: String) -> (String, Bool) {
            var modifiedLine = line
            if modifiedLine.contains("a=recvonly") {
                modifiedLine = modifiedLine.replacingOccurrences(of: "a=recvonly", with: "a=sendrecv")
                return (modifiedLine, true)
            }
            if modifiedLine.contains("a=sendonly") {
                modifiedLine = modifiedLine.replacingOccurrences(of: "a=sendonly", with: "a=sendrecv")
                return (modifiedLine, true)
            }
            if modifiedLine.contains("a=inactive") {
                modifiedLine = modifiedLine.replacingOccurrences(of: "a=inactive", with: "a=sendrecv")
                return (modifiedLine, true)
            }
            return (modifiedLine, false)
        }
        
        // Helper function to change media direction to inactive.
        func removeMedia(in line: String) async -> (String, Bool) {
            var modifiedLine = line
            if modifiedLine.contains("a=recvonly") {
                modifiedLine = modifiedLine.replacingOccurrences(of: "a=recvonly", with: "a=inactive")
                return (modifiedLine, true)
            }
            if modifiedLine.contains("a=sendonly") {
                modifiedLine = modifiedLine.replacingOccurrences(of: "a=sendonly", with: "a=inactive")
                return (modifiedLine, true)
            }
            if modifiedLine.contains("a=sendrecv") {
                modifiedLine = modifiedLine.replacingOccurrences(of: "a=sendrecv", with: "a=inactive")
                return (modifiedLine, true)
            }
            return (modifiedLine, false)
        }
        
        let lines = sdp.components(separatedBy: CharacterSet.newlines)
            .filter { !$0.trimmingCharacters(in: CharacterSet.whitespaces).isEmpty }
        
        var modifiedLines: [String] = []
        
        // Flags to indicate that we're in a media section and should modify direction attributes
        var inAudioSection = false
        var inVideoSection = false
        
        for line in lines {
            
            // Check if this line starts a new media section.
            if line.hasPrefix("m=audio") {
                inVideoSection = false
                inAudioSection = true
                modifiedLines.append(line)
                continue
            }
            if line.hasPrefix("m=video") {
                inAudioSection = false
                inVideoSection = true
                modifiedLines.append(line)
                continue
            }
            
            // Check if we're starting a new section (non-media)
            if line.hasPrefix("v=") || line.hasPrefix("o=") || line.hasPrefix("s=") || line.hasPrefix("t=") {
                inAudioSection = false
                inVideoSection = false
                modifiedLines.append(line)
                continue
            }
            
            // Process lines based on current media section
            if inAudioSection {
                // Only process lines that contain direction attributes
                if line.contains("a=recvonly") || line.contains("a=sendonly") || line.contains("a=inactive") {
                    let (modifiedLine, didModify) = sendAndReceiveMedia(in: line)
                    modifiedLines.append(modifiedLine)
                    if didModify {
                        // Once we've updated a media direction line, we can stop looking for audio direction
                        inAudioSection = false
                    }
                } else {
                    modifiedLines.append(line)
                }
            } else if inVideoSection {
                // Only process lines that contain direction attributes
                if line.contains("a=recvonly") || line.contains("a=sendonly") || line.contains("a=inactive") || line.contains("a=sendrecv") {
                    if hasVideo {
                        let (modifiedLine, didModify) = sendAndReceiveMedia(in: line)
                        modifiedLines.append(modifiedLine)
                        if didModify {
                            inVideoSection = false
                        }
                    } else {
                        // When hasVideo is false, leave video direction unchanged
                        modifiedLines.append(line)
                        inVideoSection = false
                    }
                } else {
                    modifiedLines.append(line)
                }
            } else {
                // If not in any media section, append as-is
                modifiedLines.append(line)
            }
        }
        
        // Recombine the modified lines back into a single SDP string
        return modifiedLines.joined(separator: "\n") + "\n"
    }
    
    
    
    /// Creates an SDP offer for a call with proper error handling and validation
    /// - Parameters:
    ///   - call: The call to create an offer for
    ///   - hasVideo: Whether the call supports video
    /// - Returns: BSON document containing the offer
    /// - Throws: SDPHandlerError or RTCErrors if creation fails
    public func createOffer(
        call: Call,
        hasVideo: Bool
    ) async throws -> RTCCall {
        do {
            logger.log(level: .info, message: "Creating offer for call: \(call.id), hasVideo: \(hasVideo)")
            
            // Find or create connection
            var connection: RTCConnection
            if let foundConnection = await connectionManager.findConnection(with: call.sharedCommunicationId) {
                connection = foundConnection
                logger.log(level: .debug, message: "Using existing connection for call: \(call.id)")
            } else {
                logger.log(level: .error, message: "No connection found for call: \(call.id)")
                throw RTCErrors.connectionNotFound
            }
            var rtcCall: RTCCall?
#if os(Android)
            // Generate SDP offer using the new SDPHandler
            var description: RTCSessionDescription = try await generateSDPOffer(for: connection, hasAudio: true, hasVideo: hasVideo)
            
            // Modify SDP for specific requirements
            let modified = await modifySDP(sdp: description.sdp, hasVideo: hasVideo)
            description = RTCSessionDescription(type: description.type, sdp: modified)
            
            logger.log(level: .info, message: "Generated SDP offer for call: \(call.id)")
            await Self.rtcClient.setLocalDescription(description)
            let sdp = try SessionDescription(fromRTC: description)
            // Create call object and encode
            rtcCall = RTCCall(
                sdp: sdp,
                call: call)
#elseif os(Android)
            // Generate SDP offer using the new SDPHandler
            var description: WebRTC.RTCSessionDescription = try await generateSDPOffer(for: connection, hasAudio: true, hasVideo: hasVideo)
            
            // Modify SDP for specific requirements
            let modified = await modifySDP(sdp: description.sdp, hasVideo: hasVideo)
            description = WebRTC.RTCSessionDescription(type: description.type, sdp: modified)
            
            logger.log(level: .info, message: "Generated SDP offer for call: \(call.id)")
            // Set local description
            try await connection.peerConnection.setLocalDescription(description)
            
            // Create call object and encode
            rtcCall = RTCCall(
                sdp: try SessionDescription(fromRTC: description),
                call: call)
#endif
            guard let rtcCall else {
                fatalError("Failed to create RTCCall")
            }
            
            logger.log(level: .info, message: "Successfully created offer for call: \(call.id)")
            
            return rtcCall
            
        } catch let error as SDPHandlerError {
            logger.log(level: .error, message: "SDP offer creation failed: \(error.localizedDescription)")
            await callState.transition(to: .failed(.inbound(call.supportsVideo ? .video : .voice), call, error.localizedDescription))
            await finishEndConnection(currentCall: call)
            throw error
        } catch let error as RTCErrors {
            logger.log(level: .error, message: "RTC error during offer creation: \(error.localizedDescription)")
            await callState.transition(to: .failed(.inbound(call.supportsVideo ? .video : .voice), call, error.localizedDescription))
            await finishEndConnection(currentCall: call)
            throw error
        } catch {
            logger.log(level: .error, message: "Unexpected error during offer creation: \(error)")
            await callState.transition(to: .failed(.inbound(call.supportsVideo ? .video : .voice), call, error.localizedDescription))
            await finishEndConnection(currentCall: call)
            throw RTCErrors.mediaError("Offer creation failed: \(error.localizedDescription)")
        }
    }
    
    /// Creates an SDP answer for a call with proper error handling and validation
    /// - Parameter call: The call to create an answer for
    /// - Returns: BSON document containing the answer
    /// - Throws: SDPHandlerError or RTCErrors if creation fails
    public func createAnswer(call: Call) async throws -> RTCCall {
        
        logger.log(level: .info, message: "Creating answer for call: \(call.id)")
        
        // Wait for peer connection to be ready
        try await getRunLoop().run(10, sleep: Duration.seconds(1)) { [weak self] in
            guard let self else { return false }
            var canRun = true
            if await self.getPcState() == RTCSession.PeerConnectionState.setRemote {
                canRun = false
            }
            return canRun
        }
        
        do {
            // Find or create connection
            var connection: RTCConnection
            if let foundConnection = await connectionManager.findConnection(with: call.sharedCommunicationId) {
                connection = foundConnection
                logger.log(level: .debug, message: "Using existing connection for call: \(call.id)")
            } else {
                logger.log(level: .error, message: "No connection found for call: \(call.id)")
                throw RTCErrors.connectionNotFound
            }
            
            
            var rtcCall: RTCCall?
#if os(Android)
            // Generate SDP answer using the new SDPHandler
            var description: RTCSessionDescription = try await generateSDPAnswer(for: connection, hasAudio: true, hasVideo: call.supportsVideo)
            
            // Modify SDP for specific requirements
            let modified = await modifySDP(sdp: description.sdp, hasVideo: call.supportsVideo)
            description = RTCSessionDescription(type: description.type, sdp: modified)
            
            logger.log(level: .info, message: "Generated SDP answer for call: \(call.id)")
            await Self.rtcClient.setLocalDescription(description)
            
            // Create call object and encode
            rtcCall = RTCCall(
                sdp: try SessionDescription(fromRTC: description),
                call: call)
#elseif canImport(WebRTC)
            // Generate SDP answer using the new SDPHandler
            var description: WebRTC.RTCSessionDescription = try await generateSDPAnswer(for: connection, hasAudio: true, hasVideo: call.supportsVideo)
            
            // Modify SDP for specific requirements
            let modified = await modifySDP(sdp: description.sdp, hasVideo: call.supportsVideo)
            description = WebRTC.RTCSessionDescription(type: description.type, sdp: modified)
            
            logger.log(level: .info, message: "Generated SDP answer for call: \(call.id)")
            // Set local description
            try await connection.peerConnection.setLocalDescription(description)
            
            // Create call object and encode
            rtcCall = RTCCall(
                sdp: try SessionDescription(fromRTC: description),
                call: call)
#endif
            
            guard let rtcCall else {
                fatalError()
            }
            
            logger.log(level: .info, message: "Successfully created answer for call: \(call.id)")
            
            return rtcCall
            
        } catch let error as SDPHandlerError {
            logger.log(level: .error, message: "SDP answer creation failed: \(error.localizedDescription)")
            await callState.transition(to: .failed(.inbound(call.supportsVideo ? .video : .voice), call, error.localizedDescription))
            await finishEndConnection(currentCall: call)
            throw error
        } catch let error as RTCErrors {
            logger.log(level: .error, message: "RTC error during answer creation: \(error.localizedDescription)")
            await callState.transition(to: .failed(.inbound(call.supportsVideo ? .video : .voice), call, error.localizedDescription))
            await finishEndConnection(currentCall: call)
            throw error
        } catch {
            logger.log(level: .error, message: "Unexpected error during answer creation: \(error)")
            await callState.transition(to: .failed(.inbound(call.supportsVideo ? .video : .voice), call, error.localizedDescription))
            await finishEndConnection(currentCall: call)
            throw RTCErrors.mediaError("Answer creation failed: \(error.localizedDescription)")
        }
    }
    
    /// Sets the remote SDP for a call with proper error handling and validation
    /// - Parameters:
    ///   - sdp: The remote SDP to set
    ///   - call: The call to set the SDP for
    /// - Throws: SDPHandlerError or RTCErrors if setting fails
#if os(Android)
    public func setRemote(
        sdp: RTCSessionDescription,
        call: Call
    ) async throws {
        logger.log(level: .info, message: "Setting remote SDP for call: \(call.id)")
        
        do {
            // Find or create connection
            var currentConnection: RTCConnection
            if let connection = await connectionManager.findConnection(with: call.sharedCommunicationId) {
                currentConnection = connection
                logger.log(level: .debug, message: "Using existing connection for call: \(call.id)")
            } else {
                logger.log(level: .debug, message: "Creating new connection for call: \(call.id)")
                currentConnection = try await createPeerConnection(with: call.sharedCommunicationId, hasVideo: call.supportsVideo)
            }
            
            // Modify SDP for specific requirements
            var modifiedSdp = sdp
            let modified = await modifySDP(sdp: sdp.sdp, hasVideo: call.supportsVideo)
            modifiedSdp = RTCSessionDescription(type: sdp.type, sdp: modified)
            
            // Set remote SDP using the new SDPHandler
            try await setRemoteSDP(modifiedSdp, for: currentConnection)
            
            setPcState(RTCSession.PeerConnectionState.setRemote)
            logger.log(level: .info, message: "Successfully set remote SDP for call: \(call.id)")
            
            // Start sending candidates if call is found
            if let foundCall = await calls.first(where: { $0.sharedCommunicationId == call.sharedCommunicationId }) {
                try await startSendingCandidates(call: foundCall)
            }
            
        } catch let error as SDPHandlerError {
            logger.log(level: .error, message: "Failed to set remote SDP: \(error.localizedDescription)")
            await callState.transition(to: .failed(.inbound(call.supportsVideo ? .video : .voice), call, error.localizedDescription))
            await finishEndConnection(currentCall: call)
            throw error
        } catch let error as RTCErrors {
            logger.log(level: .error, message: "RTC error setting remote SDP: \(error.localizedDescription)")
            await callState.transition(to: .failed(.inbound(call.supportsVideo ? .video : .voice), call, error.localizedDescription))
            await finishEndConnection(currentCall: call)
            throw error
        } catch {
            logger.log(level: .error, message: "Unexpected error setting remote SDP: \(error)")
            await callState.transition(to: .failed(.inbound(call.supportsVideo ? .video : .voice), call, error.localizedDescription))
            await finishEndConnection(currentCall: call)
            throw RTCErrors.mediaError("Failed to set remote SDP: \(error.localizedDescription)")
        }
    }
#endif
    
#if !os(Android)
    public func setRemote(
        sdp: WebRTC.RTCSessionDescription,
        call: Call
    ) async throws {
        logger.log(level: .info, message: "Setting remote SDP for call: \(call.id)")
        
        do {
            // Find or create connection
            var currentConnection: RTCConnection
            if let connection = await connectionManager.findConnection(with: call.sharedCommunicationId) {
                currentConnection = connection
                logger.log(level: .debug, message: "Using existing connection for call: \(call.id)")
            } else {
                logger.log(level: .debug, message: "Creating new connection for call: \(call.id)")
                currentConnection = try await createPeerConnection(with: call.sharedCommunicationId, hasVideo: call.supportsVideo)
            }
            
            // Modify SDP for specific requirements
            var modifiedSdp = sdp
            let modified = await modifySDP(sdp: sdp.sdp, hasVideo: call.supportsVideo)
            modifiedSdp = WebRTC.RTCSessionDescription(type: sdp.type, sdp: modified)
            
            // Set remote SDP using the new SDPHandler
            try await setRemoteSDP(modifiedSdp, for: currentConnection)
            
            setPcState(RTCSession.PeerConnectionState.setRemote)
            logger.log(level: .info, message: "Successfully set remote SDP for call: \(call.id)")
            
            // Start sending candidates if call is found
            if let foundCall = await calls.first(where: { $0.sharedCommunicationId == call.sharedCommunicationId }) {
                try await startSendingCandidates(call: foundCall)
            }
            
        } catch let error as SDPHandlerError {
            logger.log(level: .error, message: "Failed to set remote SDP: \(error.localizedDescription)")
            await callState.transition(to: .failed(.inbound(call.supportsVideo ? .video : .voice), call, error.localizedDescription))
            await finishEndConnection(currentCall: call)
            throw error
        } catch let error as RTCErrors {
            logger.log(level: .error, message: "RTC error setting remote SDP: \(error.localizedDescription)")
            await callState.transition(to: .failed(.inbound(call.supportsVideo ? .video : .voice), call, error.localizedDescription))
            await finishEndConnection(currentCall: call)
            throw error
        } catch {
            logger.log(level: .error, message: "Unexpected error setting remote SDP: \(error)")
            await callState.transition(to: .failed(.inbound(call.supportsVideo ? .video : .voice), call, error.localizedDescription))
            await finishEndConnection(currentCall: call)
            throw RTCErrors.mediaError("Failed to set remote SDP: \(error.localizedDescription)")
        }
    }
#endif
    
    public func setRemote(
        candidate: IceCandidate,
        call: Call
    ) async throws {
        await inboundCandidateConsumer.feedConsumer(candidate)
        guard let connection = await connectionManager.findConnection(with: call.sharedCommunicationId) else { return }
        if getPcState() == RTCSession.PeerConnectionState.setRemote {
            try await processCandidates(connection: connection)
        }
    }
    
    
    private func processCandidates(connection: RTCConnection) async throws {
        // Skip-compatible approach: process candidates directly from the consumer
        let result = await inboundCandidateConsumer.next()
        switch result {
        case NTASequenceStateMachine.NextNTAResult.ready(let candidate):
            //we need to find if last id contained in deq
            let iceCandidate = candidate.item
#if canImport(WebRTC)
            let ice: WebRTC.RTCIceCandidate = WebRTC.RTCIceCandidate(sdp: iceCandidate.sdp, sdpMLineIndex: iceCandidate.sdpMLineIndex, sdpMid: iceCandidate.sdpMid ?? "")
            try await connection.peerConnection.add(ice)
#elseif os(Android)
            let ice: RTCIceCandidate = RTCIceCandidate(sdp: iceCandidate.sdp, sdpMLineIndex: iceCandidate.sdpMLineIndex, sdpMid: iceCandidate.sdpMid ?? "")
            Self.rtcClient.addIceCandidate(ice)
#endif
            setLastId(iceCandidate.id)
            logger.log(level: .info, message: "Added Ice Candidate\n Id: \(iceCandidate.id)")
        case NTASequenceStateMachine.NextNTAResult.consumed:
            //If we consume all candidates before we refeed we have a weird state
            setNotRunning(true)
            return
        }
    }
    
    public func startSendingCandidates(call: Call) async throws {
        guard let connection = await connectionManager.findConnection(with: call.sharedCommunicationId) else { return }
        try await processCandidates(connection: connection)
        if !getIceDeque().isEmpty {
            for item in getIceDeque() {
                try await self.getDelegate()?.sendCandidate(item, call: call)
                self.logger.log(level: .info, message: "Sent Candidate, \(item.id)")
            }
            var iceDeque = getIceDeque()
            iceDeque.removeAll()
            setIceDeque(iceDeque)
        }
        setReadyForCandidates(true)
    }
    
    func downgradeToVoice(connectionId: String) async throws -> RTCCall {
        
        await self.setVideoTrack(isEnabled: false, connectionId: connectionId)
        
        guard let currentCall = await calls.first(where: { $0.sharedCommunicationId == connectionId }) else { throw RTCErrors.callNotFound }
        var call = try await createOffer(
            call: currentCall,
            hasVideo: false)
        
        call.call.updatedAt = Date()
        call.call.supportsVideo = false
        return call
    }
    
    func upgradeToVideo(connectionId: String) async throws -> RTCCall {
        await self.setVideoTrack(isEnabled: true, connectionId: connectionId)
        guard let currentCall = await calls.first(where: { $0.sharedCommunicationId == connectionId }) else { throw RTCErrors.callNotFound }
        var call = try await createOffer(
            call: currentCall,
            hasVideo: true)
        
        call.call.updatedAt = Date()
        call.call.supportsVideo = true
        return call
    }
    
    public func answerUpDowgradeOffer(
        call: Call,
        sdp: String,
        shouldAnswer: Bool,
        hasVideo: Bool
    ) async -> RTCCall? {
        do {
            var currentConnection: RTCConnection
            if let connection = await connectionManager.findConnection(with: call.sharedCommunicationId) {
                currentConnection = connection
                if hasVideo {
                    let updatedConnection = try await addVideoToStream(with: currentConnection)
                    await connectionManager.updateConnection(id: call.sharedCommunicationId, with: updatedConnection)
                    currentConnection = updatedConnection
                }
            } else {
                currentConnection = try await createPeerConnection(with: call.sharedCommunicationId, hasVideo: call.supportsVideo)
            }
            
#if !os(Android)
            try await currentConnection.peerConnection.setRemoteDescription(WebRTC.RTCSessionDescription(type: .offer, sdp: sdp))
            
#elseif SKIP
            await Self.rtcClient.setRemoteDescription(RTCSessionDescription(type: org.webrtc.SessionDescription.Type.offer, sdp: sdp))
#endif
            
            if shouldAnswer {
                var rtcCall: RTCCall?
#if !os(Android)
                var description: WebRTC.RTCSessionDescription
                let mediaConstrains = [kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue,
                                       kRTCMediaConstraintsOfferToReceiveVideo: hasVideo ? kRTCMediaConstraintsValueTrue : kRTCMediaConstraintsValueFalse]
                let constraints = WebRTC.RTCMediaConstraints(mandatoryConstraints: mediaConstrains,
                                                             optionalConstraints: nil)
                
                description = try await currentConnection.peerConnection.answer(for: constraints)
                
                
                let modified = await modifySDP(sdp: description.sdp, hasVideo: hasVideo)
                description = WebRTC.RTCSessionDescription(type: description.type, sdp: modified)
                
                self.logger.log(level: .info, message: "Local SDP Answer\n SDP: \(description)")
                
                try await currentConnection.peerConnection.setLocalDescription(description)
                
                //This is a received Remote Description set. Change the state for the UI to reflect call type
                await callState.transition(to: .waiting)
                await callState.transition(to: call.supportsVideo ? .receivedVideoUpgrade : .receivedVoiceDowngrade)
                
                rtcCall = RTCCall(
                    sdp: try SessionDescription(fromRTC: description),
                    call: call)
                
#elseif os(Android)
                var description: RTCSessionDescription
                let mediaConstrains = Self.rtcClient.createConstraints(["OfferToReceiveAudio": "true", "OfferToReceiveVideo": "\(hasVideo ? "true" : "false")"])
                description = await Self.rtcClient.createAnswer(constraints: mediaConstrains)
                
                
                let modified = await modifySDP(sdp: description.sdp, hasVideo: hasVideo)
                description = RTCSessionDescription(type: description.type, sdp: modified)
                
                self.logger.log(level: .info, message: "Local SDP Answer\n SDP: \(description)")
                
                await Self.rtcClient.setLocalDescription(description)
                
                //This is a received Remote Description set. Change the state for the UI to reflect call type
                await callState.transition(to: .waiting)
                await callState.transition(to: call.supportsVideo ? .receivedVideoUpgrade : .receivedVoiceDowngrade)
                
                rtcCall = RTCCall(
                    sdp: try SessionDescription(fromRTC: description),
                    call: call)
#endif
                guard let rtcCall else {
                    fatalError()
                }
                return rtcCall
            } else {
                return nil
            }
        } catch {
            await callState.transition(to: .failed(.inbound(call.supportsVideo ? .video : .voice), call, error.localizedDescription))
            return nil
        }
    }
}
