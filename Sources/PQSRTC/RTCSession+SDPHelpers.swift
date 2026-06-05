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
    
    func modifySDP(
        sdp: String,
        hasVideo: Bool = false,
        stripSsrcLines: Bool = false,
        vp8OnlyVideo: Bool = false,
        preserveVideoDirectionsForMids: Set<String> = [],
        forceReceiveOnlyVideoMids: Set<String> = []
    ) async -> String {
        var sdp = sdp
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let preservedVideoDirectionMids = preserveVideoDirectionsForMids
            .union(Self.screenShareVideoMids(in: sdp))
            .union(Self.receiveOnlyVideoMidsWithoutLocalMedia(in: sdp))

        func payloadType(in line: String, prefix: String) -> String? {
            guard line.hasPrefix(prefix) else { return nil }
            let rest = line.dropFirst(prefix.count)
            return rest.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init)
        }

        func containsApt(_ line: String, payloadType: String) -> Bool {
            let needle = "apt=\(payloadType)"
            guard let range = line.range(of: needle) else { return false }
            let before = range.lowerBound == line.startIndex ? nil : line[line.index(before: range.lowerBound)]
            let after = range.upperBound == line.endIndex ? nil : line[range.upperBound]
            let validBefore = before == nil || before == " " || before == "\t" || before == ";"
            let validAfter = after == nil || after == " " || after == "\t" || after == ";" || after == "\r"
            return validBefore && validAfter
        }

        func restrictVideoCodecsToVP8(_ sdp: String) -> String {
            let lines = sdp.components(separatedBy: "\n")
            var sections: [[String]] = []
            var current: [String] = []

            for line in lines {
                if line.hasPrefix("m="), !current.isEmpty {
                    sections.append(current)
                    current = []
                }
                current.append(line)
            }
            if !current.isEmpty {
                sections.append(current)
            }

            let rewritten = sections.flatMap { section -> [String] in
                guard let first = section.first, first.hasPrefix("m=video") else { return section }

                var vp8PayloadTypes = Set<String>()
                for line in section {
                    guard let pt = payloadType(in: line, prefix: "a=rtpmap:") else { continue }
                    if line.range(of: "VP8/90000", options: .caseInsensitive) != nil {
                        vp8PayloadTypes.insert(pt)
                    }
                }
                guard !vp8PayloadTypes.isEmpty else { return section }

                var keepPayloadTypes = vp8PayloadTypes
                for line in section {
                    guard let pt = payloadType(in: line, prefix: "a=fmtp:") else { continue }
                    if vp8PayloadTypes.contains(where: { containsApt(line, payloadType: $0) }) {
                        keepPayloadTypes.insert(pt)
                    }
                }

                return section.compactMap { line in
                    if line.hasPrefix("m=video") {
                        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                        guard tokens.count > 3 else { return line }
                        let header = Array(tokens.prefix(3))
                        let payloads = tokens.dropFirst(3).filter { keepPayloadTypes.contains($0) }
                        guard !payloads.isEmpty else { return line }
                        return (header + payloads).joined(separator: " ")
                    }

                    for prefix in ["a=rtpmap:", "a=rtcp-fb:", "a=fmtp:"] {
                        if let pt = payloadType(in: line, prefix: prefix) {
                            return keepPayloadTypes.contains(pt) ? line : nil
                        }
                    }
                    return line
                }
            }

            return rewritten.joined(separator: "\n")
        }

        if vp8OnlyVideo {
            sdp = restrictVideoCodecsToVP8(sdp)
        }

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

        func receiveOnlyMedia(in line: String) -> (String, Bool) {
            var modifiedLine = line
            if modifiedLine.contains("a=sendrecv") {
                modifiedLine = modifiedLine.replacingOccurrences(of: "a=sendrecv", with: "a=recvonly")
                return (modifiedLine, true)
            }
            if modifiedLine.contains("a=sendonly") {
                modifiedLine = modifiedLine.replacingOccurrences(of: "a=sendonly", with: "a=recvonly")
                return (modifiedLine, true)
            }
            if modifiedLine.contains("a=inactive") {
                modifiedLine = modifiedLine.replacingOccurrences(of: "a=inactive", with: "a=recvonly")
                return (modifiedLine, true)
            }
            if modifiedLine.contains("a=recvonly") {
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
        var currentMediaMid: String?
        
        for line in lines {
            var line = line
            
            // Legacy escape hatch only. SFU renegotiation offers must keep SSRC attributes:
            // stripping `a=ssrc:` while leaving `a=ssrc-group:FID` creates remote tracks
            // with no inbound RTP stats on Apple WebRTC.
            if stripSsrcLines {
                let lower = line.lowercased()
                if lower.hasPrefix("a=ssrc:") {
                    continue
                }
            }

            // H264 profile-level-id guidance (historical 1:1 SFU remote-video outage):
            // - 42e034 => Constrained Baseline, level 5.2 (very high; some peers/SFU hops reject or behave poorly)
            // - 42e01f => Constrained Baseline, level 3.1 (too low for 1080p; can force severe downscale or sender stalls)
            //
            // Production symptom: calls reached ICE connected with tracks attached, but remote video could
            // freeze/black-screen because the sender pipeline stalled under aggressive profile rewriting.
            //
            // Fix: cap to level 4.0 (42e028), which is stable for 1080p-ish capture while avoiding both
            // overly-high 5.x offers and overly-low 3.1 fallback.
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
                currentMediaMid = nil
                modifiedLines.append(line)
                continue
            }
            if line.hasPrefix("m=video") {
                inAudioSection = false
                inVideoSection = true
                currentMediaMid = nil
                modifiedLines.append(line)
                continue
            }
            
            // Check if we're starting a new section (non-media)
            if line.hasPrefix("v=") || line.hasPrefix("o=") || line.hasPrefix("s=") || line.hasPrefix("t=") {
                inAudioSection = false
                inVideoSection = false
                currentMediaMid = nil
                modifiedLines.append(line)
                continue
            }

            if line.hasPrefix("a=mid:") {
                currentMediaMid = String(line.dropFirst("a=mid:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
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
                    let shouldForceReceiveOnly = currentMediaMid.map {
                        forceReceiveOnlyVideoMids.contains($0)
                    } ?? false
                    let shouldPreserveDirection = currentMediaMid.map {
                        preservedVideoDirectionMids.contains($0)
                    } ?? false
                    if shouldForceReceiveOnly {
                        let (modifiedLine, didModify) = receiveOnlyMedia(in: line)
                        modifiedLines.append(modifiedLine)
                        if didModify {
                            inVideoSection = false
                        }
                    } else if shouldPreserveDirection {
                        modifiedLines.append(line)
                        inVideoSection = false
                    } else if hasVideo {
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

    nonisolated static func screenShareVideoMids(in sdp: String) -> Set<String> {
        let lines = sdp
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var mids = Set<String>()
        var currentIsVideo = false
        var currentMid: String?
        var currentHasScreenMsid = false

        func flushCurrentSection() {
            guard currentIsVideo, currentHasScreenMsid, let currentMid, !currentMid.isEmpty else { return }
            mids.insert(currentMid)
        }

        for line in lines {
            if line.hasPrefix("m=") {
                flushCurrentSection()
                currentIsVideo = line.hasPrefix("m=video")
                currentMid = nil
                currentHasScreenMsid = false
                continue
            }

            guard currentIsVideo else { continue }
            if line.hasPrefix("a=mid:") {
                currentMid = String(line.dropFirst("a=mid:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if Self.lineContainsScreenShareMsid(line) {
                currentHasScreenMsid = true
            }
        }
        flushCurrentSection()

        return mids
    }

    nonisolated static func activeScreenShareVideoMids(in sdp: String) -> Set<String> {
        let lines = sdp
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var mids = Set<String>()
        var currentIsVideo = false
        var currentMid: String?
        var currentHasScreenMsid = false
        var currentDirection: String?

        func flushCurrentSection() {
            guard currentIsVideo, currentHasScreenMsid, let currentMid, !currentMid.isEmpty else { return }
            if currentDirection == "inactive" || currentDirection == "recvonly" {
                return
            }
            mids.insert(currentMid)
        }

        for line in lines {
            if line.hasPrefix("m=") {
                flushCurrentSection()
                currentIsVideo = line.hasPrefix("m=video")
                currentMid = nil
                currentHasScreenMsid = false
                currentDirection = nil
                continue
            }

            guard currentIsVideo else { continue }
            if line.hasPrefix("a=mid:") {
                currentMid = String(line.dropFirst("a=mid:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else if line == "a=sendrecv" || line == "a=sendonly" || line == "a=recvonly" || line == "a=inactive" {
                currentDirection = String(line.dropFirst("a=".count))
            }
            if Self.lineContainsScreenShareMsid(line) {
                currentHasScreenMsid = true
            }
        }
        flushCurrentSection()

        return mids
    }

    nonisolated static func receiveOnlyVideoMidsWithoutLocalMedia(in sdp: String) -> Set<String> {
        let lines = sdp
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var mids = Set<String>()
        var currentIsVideo = false
        var currentMid: String?
        var currentDirection: String?
        var currentHasLocalMedia = false

        func flushCurrentSection() {
            guard currentIsVideo,
                  currentDirection == "recvonly",
                  !currentHasLocalMedia,
                  let currentMid,
                  !currentMid.isEmpty else { return }
            mids.insert(currentMid)
        }

        for line in lines {
            if line.hasPrefix("m=") {
                flushCurrentSection()
                currentIsVideo = line.hasPrefix("m=video")
                currentMid = nil
                currentDirection = nil
                currentHasLocalMedia = false
                continue
            }

            guard currentIsVideo else { continue }
            if line.hasPrefix("a=mid:") {
                currentMid = String(line.dropFirst("a=mid:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else if line == "a=sendrecv" || line == "a=sendonly" || line == "a=recvonly" || line == "a=inactive" {
                currentDirection = String(line.dropFirst("a=".count))
            } else if line.hasPrefix("a=msid:") ||
                        line.hasPrefix("a=ssrc:") ||
                        line.hasPrefix("a=ssrc-group:") {
                currentHasLocalMedia = true
            }
        }
        flushCurrentSection()

        return mids
    }

    private nonisolated static func lineContainsScreenShareMsid(_ line: String) -> Bool {
        let remainder: String
        if line.hasPrefix("a=msid:") {
            remainder = String(line.dropFirst("a=msid:".count))
        } else if let range = line.range(of: " msid:") {
            remainder = String(line[range.upperBound...])
        } else {
            return false
        }

        return remainder
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .contains {
                $0.hasPrefix(Self.screenTrackPrefix)
                    || $0.hasPrefix("streamId_\(Self.screenTrackPrefix)")
            }
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
            self.logger.log(level: .info, message: "Apple Platform Offer SDP summary connection=\(connection.id): \(RTCSdpDiagnostics.summary(description.sdp))")
            
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
            self.logger.log(level: .info, message: "Apple Platform Answer SDP summary connection=\(connection.id): \(RTCSdpDiagnostics.summary(description.sdp))")
            
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
            self.logger.log(level: .info, message: "Remote SDP summary before set connection=\(connection.id): \(RTCSdpDiagnostics.summary(sdp.sdp))")
            try await connection.peerConnection.setRemoteDescription(sdp)
            self.logger.log(level: .info, message: "Successfully set remote SDP\n \(sdp.sdp)")
            self.logger.log(level: .info, message: "Remote SDP summary after set connection=\(connection.id): \(RTCSdpDiagnostics.summary(sdp.sdp))")
            await reconcileAppleRemoteParticipantCameraTracksAfterSetRemoteSDP(sdp.sdp, connectionId: connection.id)
            await reconcileAppleRemoteParticipantAudioTracksAfterSetRemoteSDP(sdp.sdp, connectionId: connection.id)
            await reconcileAppleRemoteScreenTracksAfterSetRemoteSDP(sdp.sdp, connectionId: connection.id)
            self.logger.log(level: .info, message: "PeerConnection media graph after setRemoteSDP connection=\(connection.id): \(RTCPeerConnectionMediaDiagnostics.summary(connection.peerConnection))")
            
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
            
            self.logger.log(level: .info, message: "Android Offer SDP summary connection=\(connection.id): \(RTCSdpDiagnostics.summary(description.sdp))")
            
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
            
            self.logger.log(level: .info, message: "Android Answer SDP summary connection=\(connection.id): \(RTCSdpDiagnostics.summary(description.sdp))")
            
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
            self.logger.log(level: .info, message: "Remote SDP summary before set connection=\(connection.id): \(RTCSdpDiagnostics.summary(sdp.sdp))")
            try await client.setRemoteDescription(sdp)
            self.logger.log(level: .info, message: "Successfully set remote SDP\n \(sdp.sdp)")
            self.logger.log(level: .info, message: "Remote SDP summary after set connection=\(connection.id): \(RTCSdpDiagnostics.summary(sdp.sdp))")
            await reconcileAndroidRemoteParticipantCameraTracksAfterSetRemoteSDP(sdp.sdp, connectionId: connection.id)
            await reconcileAndroidRemoteScreenTracksAfterSetRemoteSDP(sdp.sdp, connectionId: connection.id)
            
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
