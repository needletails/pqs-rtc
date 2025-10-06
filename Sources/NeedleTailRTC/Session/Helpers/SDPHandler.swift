//
//  SDPHandler.swift
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
@preconcurrency import WebRTC
#endif
import Foundation
import NeedleTailLogger

/// Errors that can occur during SDP handling operations
public enum SDPHandlerError: Error, Sendable {
    case invalidSDPFormat(String)
    case unsupportedMediaType(String)
    case sdpGenerationFailed(String)
    case sdpParsingFailed(String)
    case invalidConstraints(String)
    
    public var errorDescription: String? {
        switch self {
        case .invalidSDPFormat(let message):
            return "Invalid SDP format: \(message)"
        case .unsupportedMediaType(let type):
            return "Unsupported media type: \(type)"
        case .sdpGenerationFailed(let reason):
            return "SDP generation failed: \(reason)"
        case .sdpParsingFailed(let reason):
            return "SDP parsing failed: \(reason)"
        case .invalidConstraints(let reason):
            return "Invalid constraints: \(reason)"
        }
    }
}

extension RTCSession {
    
    /// Validates SDP format and content
    /// - Parameter sdp: The SDP string to validate
    /// - Returns: True if valid, false otherwise
    private nonisolated func validateSDP(_ sdp: String) -> Bool {
        guard !sdp.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty else {
            return false
        }
        
        // Basic SDP validation - should start with v=0
        guard sdp.hasPrefix("v=0") else {
            return false
        }
        
        // Check for required SDP sections
        let requiredSections = ["o=", "s=", "t="]
        for section in requiredSections {
            guard sdp.contains(section) else {
                return false
            }
        }
        
        return true
    }
    
#if !os(Android)
    /// Creates media constraints for SDP generation
    /// - Parameters:
    ///   - hasAudio: Whether to include audio
    ///   - hasVideo: Whether to include video
    /// - Returns: RTCMediaConstraints object
    /// - Throws: SDPHandlerError if constraints are invalid
    private nonisolated func createMediaConstraints(hasAudio: Bool, hasVideo: Bool) throws -> WebRTC.RTCMediaConstraints {
        guard hasAudio || hasVideo else {
            throw SDPHandlerError.invalidConstraints("At least one media type must be enabled")
        }
        
        var mandatoryConstraints: [String: String] = [:]
        
        if hasAudio {
            mandatoryConstraints[kRTCMediaConstraintsOfferToReceiveAudio] = kRTCMediaConstraintsValueTrue
        }
        
        if hasVideo {
            mandatoryConstraints[kRTCMediaConstraintsOfferToReceiveVideo] = kRTCMediaConstraintsValueTrue
        }
        
        // Optional constraints for better compatibility
        let optionalConstraints: [String: String] = [
            "DtlsSrtpKeyAgreement": kRTCMediaConstraintsValueTrue,
            "googDscp": kRTCMediaConstraintsValueTrue
        ]
        
        let constraints = WebRTC.RTCMediaConstraints(
            mandatoryConstraints: mandatoryConstraints,
            optionalConstraints: optionalConstraints
        )
        
        return constraints
    }

    /// Safely generates an SDP offer with proper error handling
    /// - Parameters:
    ///   - connection: The peer connection to generate offer for
    ///   - hasAudio: Whether to include audio
    ///   - hasVideo: Whether to include video
    /// - Returns: RTCSessionDescription offer
    /// - Throws: SDPHandlerError if generation fails
    nonisolated func generateSDPOffer(
        for connection: RTCConnection,
        hasAudio: Bool,
        hasVideo: Bool
    ) async throws -> WebRTC.RTCSessionDescription {
        do {
            let constraints = try createMediaConstraints(hasAudio: hasAudio, hasVideo: hasVideo)
            
            self.logger.log(level: .info, message: "Generating SDP offer for connection: \(connection.id)")
          
            let description = try await connection.peerConnection.offer(for: constraints)
            
            guard validateSDP(description.sdp) else {
                throw SDPHandlerError.invalidSDPFormat("Generated SDP failed validation")
            }
            
            self.logger.log(level: .info, message: "Successfully generated SDP offer")
            return description
        } catch let error as SDPHandlerError {
            self.logger.log(level: .error, message: "SDP offer generation failed: \(error.localizedDescription)")
            throw error
        } catch {
            self.logger.log(level: .error, message: "Unexpected error during SDP offer generation: \(error)")
            throw SDPHandlerError.sdpGenerationFailed(error.localizedDescription)
        }
    }
    
    /// Safely generates an SDP answer with proper error handling
    /// - Parameters:
    ///   - connection: The peer connection to generate answer for
    ///   - hasAudio: Whether to include audio
    ///   - hasVideo: Whether to include video
    /// - Returns: RTCSessionDescription answer
    /// - Throws: SDPHandlerError if generation fails
    nonisolated func generateSDPAnswer(
        for connection: RTCConnection,
        hasAudio: Bool,
        hasVideo: Bool
    ) async throws -> WebRTC.RTCSessionDescription {
        do {
            let constraints = try createMediaConstraints(hasAudio: hasAudio, hasVideo: hasVideo)
            
            self.logger.log(level: .info, message: "Generating SDP answer for connection: \(connection.id)")
            
            let description = try await connection.peerConnection.answer(for: constraints)
            
            guard validateSDP(description.sdp) else {
                throw SDPHandlerError.invalidSDPFormat("Generated SDP failed validation")
            }
            
            self.logger.log(level: .info, message: "Successfully generated SDP answer")
            return description
        } catch let error as SDPHandlerError {
            self.logger.log(level: .error, message: "SDP answer generation failed: \(error.localizedDescription)")
            throw error
        } catch {
            self.logger.log(level: .error, message: "Unexpected error during SDP answer generation: \(error)")
            throw SDPHandlerError.sdpGenerationFailed(error.localizedDescription)
        }
    }
    
    nonisolated func setRemoteSDP(
        _ sdp: WebRTC.RTCSessionDescription,
        for connection: RTCConnection
    ) async throws {
        do {
            guard validateSDP(sdp.sdp) else {
                throw SDPHandlerError.invalidSDPFormat("Remote SDP failed validation")
            }
            
            self.logger.log(level: .info, message: "Setting remote SDP for connection: \(connection.id)")
            try await connection.peerConnection.setRemoteDescription(sdp)
            self.logger.log(level: .info, message: "Successfully set remote SDP")
            
        } catch let error as SDPHandlerError {
            self.logger.log(level: .error, message: "Failed to set remote SDP: \(error.localizedDescription)")
            throw error
        } catch {
            self.logger.log(level: .error, message: "Unexpected error setting remote SDP: \(error)")
            throw SDPHandlerError.sdpParsingFailed(error.localizedDescription)
        }
    }
#endif
    
#if os(Android) 
    nonisolated func generateSDPOffer(
        for connection: RTCConnection,
        hasAudio: Bool,
        hasVideo: Bool
    ) async throws -> RTCSessionDescription {
        do {
            let constraints = RTCSession.rtcClient.createConstraints(["OfferToReceiveAudio": "\(hasAudio)", "OfferToReceiveVideo": "\(hasVideo)"])
            self.logger.log(level: .info, message: "Generating SDP offer for connection: \(connection.id)")
            
            let client: RTCClient = RTCSession.rtcClient
            let description: RTCSessionDescription = await client.createOffer(constraints: constraints)
            
            guard validateSDP(description.sdp) else {
                throw SDPHandlerError.invalidSDPFormat("Generated SDP failed validation")
            }
            
            self.logger.log(level: .info, message: "Successfully generated SDP offer")
            return description
        } catch let error as SDPHandlerError {
            self.logger.log(level: .error, message: "SDP offer generation failed: \(error.localizedDescription)")
            throw error
        } catch {
            self.logger.log(level: .error, message: "Unexpected error during SDP offer generation: \(error)")
            throw SDPHandlerError.sdpGenerationFailed(error.localizedDescription)
        }
    }
    
    nonisolated func generateSDPAnswer(
        for connection: RTCConnection,
        hasAudio: Bool,
        hasVideo: Bool
    ) async throws -> RTCSessionDescription {
        do {
            let client: RTCClient = RTCSession.rtcClient
            let constraints = client.createConstraints(["OfferToReceiveAudio": "\(hasAudio)", "OfferToReceiveVideo": "\(hasVideo)"])
            
            self.logger.log(level: .info, message: "Generating SDP answer for connection: \(connection.id)")
            
            let description = await client.createAnswer(constraints: constraints)
            
            guard validateSDP(description.sdp) else {
                throw SDPHandlerError.invalidSDPFormat("Generated SDP failed validation")
            }
            
            self.logger.log(level: .info, message: "Successfully generated SDP answer")
            return description
        } catch let error as SDPHandlerError {
            self.logger.log(level: .error, message: "SDP answer generation failed: \(error.localizedDescription)")
            throw error
        } catch {
            self.logger.log(level: .error, message: "Unexpected error during SDP answer generation: \(error)")
            throw SDPHandlerError.sdpGenerationFailed(error.localizedDescription)
        }
    }
    
    nonisolated func setRemoteSDP(
        _ sdp: RTCSessionDescription,
        for connection: RTCConnection
    ) async throws {
        do {
            let client: RTCClient = RTCSession.rtcClient
            guard validateSDP(sdp.sdp) else {
                throw SDPHandlerError.invalidSDPFormat("Remote SDP failed validation")
            }
            
            self.logger.log(level: .info, message: "Setting remote SDP for connection: \(connection.id)")
            await client.setRemoteDescription(sdp)
            self.logger.log(level: .info, message: "Successfully set remote SDP")
            
        } catch let error as SDPHandlerError {
            self.logger.log(level: .error, message: "Failed to set remote SDP: \(error.localizedDescription)")
            throw error
        } catch {
            self.logger.log(level: .error, message: "Unexpected error setting remote SDP: \(error)")
            throw SDPHandlerError.sdpParsingFailed(error.localizedDescription)
        }
    }
#endif
}
