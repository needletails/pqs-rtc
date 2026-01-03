//
//  RTCSession+Exchange.swift
//  pqs-rtc
//
//  Created by Cole M on 9/11/24.
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

import Foundation
import NeedleTailAsyncSequence
import NeedleTailLogger
import BinaryCodable
#if !os(Android)
@preconcurrency import WebRTC
#endif
#if SKIP
import org.webrtc.__
#endif

extension RTCSession {
    
    func modifySDP(sdp: String, hasVideo: Bool = false) async -> String {
        let sdp = sdp
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
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
            var line = line
            if line.contains("level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e034") { // Don't allow high level
                line = line.replacingOccurrences(of: "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e034", with: "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f")
            }
            
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
    func createOffer(call: Call) async throws -> Call {
        do {
            let hasVideo = call.supportsVideo
            logger.log(level: .info, message: "Creating offer for call: \(call.id), hasVideo: \(hasVideo)")

            // ICE gathering + negotiation callbacks are emitted via the internal peer-notifications
            // stream. If the consumer task exited during a previous teardown, restart it here so
            // we don't miss generated ICE candidates on subsequent calls.
            handleNotificationsStream()
            
            // Find or create connection
            var connection: RTCConnection!
            if let foundConnection = await connectionManager.findConnection(with: call.sharedCommunicationId) {
                connection = foundConnection
                logger.log(level: .debug, message: "Found connection for call: \(call.id)")
            } else {
                logger.log(level: .error, message: "No connection found for call: \(call.id)")
                throw RTCErrors.connectionNotFound
            }
            var sdp: SessionDescription
#if os(Android)
            // Generate SDP offer using the new SDPHandler
            var description: RTCSessionDescription = try await generateSDPOffer(for: connection, hasAudio: true, hasVideo: hasVideo)
            
            // SKIP INSERT: android.util.Log.d("RTCClient", "Android: generateSDPOffer completed")
            // SKIP INSERT: android.util.Log.d("RTCClient", "Android Offer SDP:\n" + description.sdp)
            
            // Modify SDP for specific requirements
            let modified = await modifySDP(sdp: description.sdp, hasVideo: hasVideo)
            description = RTCSessionDescription(typeDescription: description.typeDescription, sdp: modified)
            
            // SKIP INSERT: android.util.Log.d("RTCClient", "Android Modified Offer SDP:\n" + description.sdp)
            logger.log(level: .info, message: "Android Modified Offer SDP:\n\(description.sdp)")
            
            logger.log(level: .info, message: "Generated SDP offer for call: \(call.id)")
            try await self.rtcClient.setLocalDescription(description)
            sdp = try SessionDescription(fromRTC: description)
#else
            // Generate SDP offer using the new SDPHandler
            var description: WebRTC.RTCSessionDescription = try await generateSDPOffer(for: connection, hasAudio: true, hasVideo: hasVideo)
            
            // Modify SDP for specific requirements
            let modified = await modifySDP(sdp: description.sdp, hasVideo: hasVideo)
            description = WebRTC.RTCSessionDescription(type: description.type, sdp: modified)
            
            logger.log(level: .info, message: "Apple Platform Modified Offer SDP:\n\(description.sdp)")
            
            logger.log(level: .info, message: "Generated SDP offer for call: \(call.id)")
            // Set local description
            try await connection.peerConnection.setLocalDescription(description)
            
            sdp = try SessionDescription(fromRTC: description)
#endif
            
            logger.log(level: .info, message: "Successfully created offer for call: \(call.id)")
            var call = call
            call.metadata = try BinaryEncoder().encode(sdp)
            return call
            
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
    /// - Returns: Call with SDP in metadata
    /// - Throws: SDPHandlerError or RTCErrors if creation fails
    func createAnswer(call: Call) async throws -> Call {
        
        logger.log(level: .info, message: "Creating answer for call: \(call.id)")

        // Ensure peer-notifications consumer is running before setting descriptions.
        handleNotificationsStream()
        
        // Wait for peer connection to be ready
        try await loop.run(10, sleep: Duration.seconds(1)) { [weak self] in
            guard let self else { return false }
            var canRun = true
            let state = await self.pcStateByConnectionId[call.sharedCommunicationId] ?? .none
            if state == .setRemote {
                canRun = false
            }
            return canRun
        }
        
        do {
            // Find or create connection
            var connection: RTCConnection
            if let foundConnection = await connectionManager.findConnection(with: call.sharedCommunicationId) {
                connection = foundConnection
                logger.log(level: .debug, message: "Found connection for call: \(call)")
            } else {
                logger.log(level: .error, message: "No connection found for call: \(call)")
                throw RTCErrors.connectionNotFound
            }
            
            
            var sdp: SessionDescription
#if os(Android)
            // Generate SDP answer using the new SDPHandler
            var description: RTCSessionDescription = try await generateSDPAnswer(for: connection, hasAudio: true, hasVideo: call.supportsVideo)
            
            // SKIP INSERT: android.util.Log.d("RTCClient", "Android: generateSDPAnswer completed")
            // SKIP INSERT: android.util.Log.d("RTCClient", "Android Answer SDP:\n" + description.sdp)
            
            // Modify SDP for specific requirements
            let modified = await modifySDP(sdp: description.sdp, hasVideo: call.supportsVideo)
            description = RTCSessionDescription(typeDescription: description.typeDescription, sdp: modified)
            
            // SKIP INSERT: android.util.Log.d("RTCClient", "Android Modified Answer SDP:\n" + description.sdp)
            logger.log(level: .info, message: "Android Modified Answer SDP:\n\(description.sdp)")
            
            logger.log(level: .info, message: "Generated SDP answer for call: \(call.id)")
            try await self.rtcClient.setLocalDescription(description)
            
            sdp = try SessionDescription(fromRTC: description)
#elseif canImport(WebRTC)
            var description: WebRTC.RTCSessionDescription = try await generateSDPAnswer(for: connection, hasAudio: true, hasVideo: call.supportsVideo)
            
            // Modify SDP for specific requirements
            let modified = await modifySDP(sdp: description.sdp, hasVideo: call.supportsVideo)
            description = WebRTC.RTCSessionDescription(type: description.type, sdp: modified)
            
            logger.log(level: .info, message: "Apple Platform Modified Answer SDP:\n\(description.sdp)")
            
            logger.log(level: .info, message: "Generated SDP answer for call: \(call.id)")
            // Set local description
            try await connection.peerConnection.setLocalDescription(description)
            
            sdp = try SessionDescription(fromRTC: description)
#endif
            
            logger.log(level: .info, message: "Successfully created answer for call: \(call.id)")
            var callWithSDP = call
            let sdpData = try BinaryEncoder().encode(sdp)
            callWithSDP.metadata = sdpData
            return callWithSDP
            
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
    func setRemote(
        sdp: RTCSessionDescription,
        call: Call
    ) async throws {
        logger.log(level: .info, message: "Setting remote SDP for call: \(call.id)")

        // Remote description can trigger negotiation/ICE events; ensure consumer is alive.
        handleNotificationsStream()
        
        do {
            // Find or create connection
            var currentConnection: RTCConnection
            if let connection = await connectionManager.findConnection(with: call.sharedCommunicationId) {
                currentConnection = connection
                logger.log(level: .info, message: "Found connection for call: \(call.id)")
            } else {
                logger.log(level: .info, message: "Creating new connection for call: \(call.id)")
                // The peer connection now requires crypto identities. Build them using the existing
                // session helper, then fetch the created connection.
                try await createCryptoSession(with: call)
                guard let created = await connectionManager.findConnection(with: call.sharedCommunicationId) else {
                    throw RTCErrors.connectionNotFound
                }
                currentConnection = created
            }
            
            // Modify SDP for specific requirements
            var modifiedSdp = sdp
            let modified = await modifySDP(sdp: sdp.sdp, hasVideo: call.supportsVideo)
            modifiedSdp = RTCSessionDescription(typeDescription: sdp.typeDescription, sdp: modified)
            
            // Set remote SDP using the new SDPHandler
            try await setRemoteSDP(modifiedSdp, for: currentConnection)
            
            pcState = PeerConnectionState.setRemote
            logger.log(level: .info, message: "Successfully set remote SDP for call: \(call.id)")
            
            // Process any queued incoming candidates that arrived before setRemote
            do {
                try await processAllQueuedCandidates(connection: currentConnection)
            } catch {
                logger.log(level: .warning, message: "Error processing queued candidates: \(error.localizedDescription)")
            }
            
            // Start sending candidates if call is found
            if let foundCall = await connectionManager.findConnection(with: call.sharedCommunicationId)?.call {
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
    func setRemote(
        sdp: WebRTC.RTCSessionDescription,
        call: Call
    ) async throws {
        logger.log(level: .info, message: "Setting remote SDP for call: \(call.id)")

        // Remote description can trigger negotiation/ICE events; ensure consumer is alive.
        handleNotificationsStream()
        
        do {
            let connection: RTCConnection
            if let existing = await connectionManager.findConnection(with: call.sharedCommunicationId) {
                connection = existing
                logger.log(level: .debug, message: "Found connection for call: \(call.id)")
            } else {
                logger.log(level: .info, message: "No connection found for call \(call.id); creating peer connection before applying remote SDP")
                try await createCryptoSession(with: call)
                guard let created = await connectionManager.findConnection(with: call.sharedCommunicationId) else {
                    throw RTCErrors.connectionNotFound
                }
                connection = created
            }
            
            // Modify SDP for specific requirements
            var modifiedSdp = sdp
            let modified = await modifySDP(sdp: sdp.sdp, hasVideo: call.supportsVideo)
            modifiedSdp = WebRTC.RTCSessionDescription(type: sdp.type, sdp: modified)
            
            // Set remote SDP using the new SDPHandler
            try await setRemoteSDP(modifiedSdp, for: connection)
            
            pcState = PeerConnectionState.setRemote
            pcStateByConnectionId[call.sharedCommunicationId] = .setRemote
            logger.log(level: .info, message: "Successfully set remote SDP for call: \(call.id)")
            
            // Process any queued incoming candidates that arrived before setRemote
            do {
                let consumer = inboundCandidateConsumer(for: call.sharedCommunicationId)
                try await processAllQueuedCandidates(connection: connection, consumer: consumer)
            } catch {
                logger.log(level: .warning, message: "Error processing queued candidates: \(error.localizedDescription)")
            }
            
            // Start sending candidates if call is found
            if let foundCall = await connectionManager.findConnection(with: call.sharedCommunicationId)?.call {
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
    
    func setRemote(
        candidate: IceCandidate,
        call: Call
    ) async throws {
        logger.log(level: .info, message: "Received ICE candidate with id: \(candidate.id) for call: \(call.id)")
        let consumer = inboundCandidateConsumer(for: call.sharedCommunicationId)
        await consumer.feedConsumer(candidate)
        guard let connection = await connectionManager.findConnection(with: call.sharedCommunicationId) else {
            logger.log(level: .warning, message: "No connection found for candidate with id: \(candidate.id), call: \(call.id)")
            return
        }
        let state = pcStateByConnectionId[call.sharedCommunicationId] ?? pcState
        logger.log(level: .info, message: "Current pcState: \(state), checking if ready to process candidates")
        if state == PeerConnectionState.setRemote {
            logger.log(level: .info, message: "Processing candidates for call: \(call.id)")
            try await processAllQueuedCandidates(connection: connection, consumer: consumer)
        } else {
            logger.log(level: .warning, message: "Not processing candidate yet - pcState is \(state), waiting for setRemote state")
        }
    }
    
    
    private func processCandidates(connection: RTCConnection, consumer: NeedleTailAsyncConsumer<IceCandidate>) async throws {
        // Skip-compatible approach: process candidates directly from the consumer
        let result = await consumer.next()
        switch result {
        case NTASequenceStateMachine.NextNTAResult.ready(let candidate):
            //we need to find if last id contained in deq
            let iceCandidate = candidate.item
#if canImport(WebRTC)
            let ice: WebRTC.RTCIceCandidate = WebRTC.RTCIceCandidate(sdp: iceCandidate.sdp, sdpMLineIndex: iceCandidate.sdpMLineIndex, sdpMid: iceCandidate.sdpMid ?? "")
            try await connection.peerConnection.add(ice)
#elseif os(Android)
            let ice: RTCIceCandidate = RTCIceCandidate(sdp: iceCandidate.sdp, sdpMLineIndex: iceCandidate.sdpMLineIndex, sdpMid: iceCandidate.sdpMid ?? "")
            try self.rtcClient.addIceCandidate(ice)
#endif
            lastId = iceCandidate.id
            logger.log(level: .info, message: "Added Ice Candidate\n Id: \(iceCandidate.id)")
        case NTASequenceStateMachine.NextNTAResult.consumed:
            //If we consume all candidates before we refeed we have a weird state
            notRunning = true
            return
        }
    }
    
    /// Processes all queued incoming ICE candidates
    /// This is called after setRemote to process any candidates that arrived early
    private func processAllQueuedCandidates(connection: RTCConnection, consumer: NeedleTailAsyncConsumer<IceCandidate>) async throws {
        var processedCount = 0
        while true {
            let result = await consumer.next()
            switch result {
            case NTASequenceStateMachine.NextNTAResult.ready(let candidate):
                let iceCandidate = candidate.item
#if canImport(WebRTC)
                let ice: WebRTC.RTCIceCandidate = WebRTC.RTCIceCandidate(sdp: iceCandidate.sdp, sdpMLineIndex: iceCandidate.sdpMLineIndex, sdpMid: iceCandidate.sdpMid ?? "")
                try await connection.peerConnection.add(ice)
#elseif os(Android)
                let ice: RTCIceCandidate = RTCIceCandidate(sdp: iceCandidate.sdp, sdpMLineIndex: iceCandidate.sdpMLineIndex, sdpMid: iceCandidate.sdpMid ?? "")
                try self.rtcClient.addIceCandidate(ice)
#endif
                lastId = iceCandidate.id
                processedCount += 1
                logger.log(level: .info, message: "Processed queued Ice Candidate Id: \(iceCandidate.id)")
            case NTASequenceStateMachine.NextNTAResult.consumed:
                if processedCount > 0 {
                    logger.log(level: .info, message: "Processed \(processedCount) queued ICE candidate(s) after setRemote")
                }
                return
            }
        }
    }
    
    public func startSendingCandidates(call: Call) async throws {
        guard await connectionManager.findConnection(with: call.sharedCommunicationId) != nil else { return }
        if !iceDeque.isEmpty {
            for item in iceDeque {
                try await self.requireTransport().sendCandidate(item, call: call)
                self.logger.log(level: .info, message: "Sent Candidate, \(item.id)")
            }
            iceDeque.removeAll()
        }
        readyForCandidates = true
    }
    
    func processDataMessage(connectionId: String,
                            channelLabel: String,
                            data: Data) async throws {
        let message = RTCDataChannelMessage(
            connectionId: connectionId,
            channelLabel: channelLabel,
            data: data)

        if let handler = dataChannelMessageHandler {
            await handler(message)
            return
        }

        if let text = String(data: data, encoding: .utf8) {
            logger.log(level: .info, message: "Unhandled data channel message (label=\(channelLabel)) text=\(text)")
        } else {
            logger.log(level: .info, message: "Unhandled data channel message (label=\(channelLabel)) bytes=\(data.count)")
        }
    }
}
