//
//  RTCSession+SDPHelpers.swift
//  pqs-rtc
//
//  Created by Cole M on 12/3/25.
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
            // H264 profile-level-id guidance:
            // - 42e034 => Constrained Baseline, level 5.2 (very high)
            // - 42e01f => Constrained Baseline, level 3.1 (too low for 1080p; can force severe downscale or stall some pipelines)
            //
            // We cap at level 4.0 which supports 1080p @ ~30fps while avoiding the very-high 5.x levels.
            // This has proven more stable than forcing 3.1 when the capture source is 1080x1920.
            if line.contains("level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e034") {
                line = line.replacingOccurrences(
                    of: "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e034",
                    with: "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e028"
                )
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
            
            self.logger.log(level: .info, message: "Apple Platform Offer SDP:\n\(description.sdp)")
            
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
            
            self.logger.log(level: .info, message: "Apple Platform Answer SDP:\n\(description.sdp)")
            
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
            self.logger.log(level: .info, message: "Successfully set remote SDP\n \(sdp.sdp)")
            
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
            let constraints = self.rtcClient.createConstraints(["OfferToReceiveAudio": "\(hasAudio)", "OfferToReceiveVideo": "\(hasVideo)"])
            self.logger.log(level: .info, message: "Generating SDP offer for connection: \(connection.id)")
            
            let client: AndroidRTCClient = self.rtcClient
            
            // SKIP INSERT: android.util.Log.d("AndroidRTCClient", "Android: Starting createOffer in SDPHandler")
            // SKIP INSERT: android.util.Log.d("AndroidRTCClient", "Android: Connection ID: " + connection.id)
            
            let description: RTCSessionDescription = try await client.createOffer(constraints: constraints)
            
            // SKIP INSERT: android.util.Log.d("AndroidRTCClient", "Android: createOffer completed in SDPHandler")
            // SKIP INSERT: android.util.Log.d("AndroidRTCClient", "Android Offer SDP:\n" + description.sdp)
            
            self.logger.log(level: .info, message: "Android Offer SDP:\n\(description.sdp)")
            
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
            let client: AndroidRTCClient = self.rtcClient
            let constraints = client.createConstraints(["OfferToReceiveAudio": "\(hasAudio)", "OfferToReceiveVideo": "\(hasVideo)"])
            
            self.logger.log(level: .info, message: "Generating SDP answer for connection: \(connection.id)")
            
            let description = try await client.createAnswer(constraints: constraints)
            
            self.logger.log(level: .info, message: "Android Answer SDP:\n\(description.sdp)")
            
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
            let client: AndroidRTCClient = self.rtcClient
            guard validateSDP(sdp.sdp) else {
                throw SDPHandlerError.invalidSDPFormat("Remote SDP failed validation")
            }
            
            self.logger.log(level: .info, message: "Setting remote SDP for connection: \(connection.id)")
            try await client.setRemoteDescription(sdp)
            self.logger.log(level: .info, message: "Successfully set remote SDP\n \(sdp.sdp)")
            
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
