//
//  IceCandidate.swift
//  needle-tail-rtc
//
//  Created by Cole M on 1/11/25.
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
#if canImport(FoundationEssentials)
import FoundationEssentials
#endif
#if !os(Android)
import WebRTC
#endif

//import NeedleTailLogger

/// Errors that can occur during ICE candidate operations.
public enum IceCandidateError: Error, Sendable {
    case invalidSDP(String)
    case invalidMLineIndex(Int32)
    case invalidID(Int)
    case conversionFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .invalidSDP(let message):
            return "Invalid SDP: \(message)"
        case .invalidMLineIndex(let index):
            return "Invalid m-line index: \(index)"
        case .invalidID(let id):
            return "Invalid candidate ID: \(id)"
        case .conversionFailed(let reason):
            return "ICE candidate conversion failed: \(reason)"
        }
    }
}

/// A Swift wrapper over `RTCIceCandidate` for easy encoding and decoding.
///
/// This struct provides a safe, thread-safe interface for working with WebRTC ICE candidates
/// in production environments. It includes validation and error handling for robust operation.
///
/// ## Usage
/// ```swift
/// // Create from RTCIceCandidate
/// let rtcCandidate = RTCIceCandidate(sdp: "candidate:...", sdpMLineIndex: 0, sdpMid: "0")
/// let candidate = IceCandidate(from: rtcCandidate, id: 1)
///
/// // Convert back to RTCIceCandidate
/// let rtcCandidate = candidate.rtcIceCandidate
/// ```
///
/// ## Thread Safety
/// This struct is marked as `Sendable` to ensure thread safety when used in concurrent contexts.
public struct IceCandidate: Codable, Sendable {
    
    /// The unique identifier for this ICE candidate.
    /// Used for tracking and correlation in production systems.
    public let id: Int
    
    /// The SDP (Session Description Protocol) string for this candidate.
    /// Contains the candidate's network information and connection details.
    public let sdp: String
    
    /// The m-line index for this candidate.
    /// Indicates which media line this candidate belongs to.
    public let sdpMLineIndex: Int32
    
    /// The SDP mid (media identification) for this candidate.
    /// Optional identifier for the media stream this candidate belongs to.
    public let sdpMid: String?
    
    
    #if !os(Android)
    /// Initializes a new instance of `IceCandidate` from an `RTCIceCandidate`.
    ///
    /// Creates a Swift wrapper around the WebRTC ICE candidate with validation
    /// for production safety.
    ///
    /// - Parameters:
    ///   - iceCandidate: The WebRTC ICE candidate to wrap
    ///   - id: A unique identifier for this candidate
    ///
    /// - Throws: `IceCandidateError` if the candidate data is invalid
    public init(from iceCandidate: WebRTC.RTCIceCandidate, id: Int) throws {
        // Validate input parameters for production safety
        guard id >= 0 else {
            throw IceCandidateError.invalidID(id)
        }
        guard !iceCandidate.sdp.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty else {
            throw IceCandidateError.invalidSDP("SDP cannot be empty")
        }
        guard iceCandidate.sdpMLineIndex >= 0 else {
            throw IceCandidateError.invalidMLineIndex(iceCandidate.sdpMLineIndex)
        }
        
        self.id = id
        self.sdp = iceCandidate.sdp.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        self.sdpMLineIndex = iceCandidate.sdpMLineIndex
        self.sdpMid = iceCandidate.sdpMid?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }
    
    /// Converts this Swift wrapper back to a WebRTC `RTCIceCandidate`.
    ///
    /// This method safely converts the validated Swift struct back to the WebRTC type
    /// for use in WebRTC operations.
    ///
    /// - Returns: A `RTCIceCandidate` instance with the same data
    public var rtcIceCandidate: WebRTC.RTCIceCandidate {
        return WebRTC.RTCIceCandidate(sdp: self.sdp, sdpMLineIndex: self.sdpMLineIndex, sdpMid: self.sdpMid ?? "")
    }
    #else
    public init(from iceCandidate: RTCIceCandidate, id: Int) throws {
        // Validate input parameters for production safety
        guard id >= 0 else {
            throw IceCandidateError.invalidID(id)
        }
        guard !iceCandidate.sdp.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty else {
            throw IceCandidateError.invalidSDP("SDP cannot be empty")
        }
        guard iceCandidate.sdpMLineIndex >= 0 else {
            throw IceCandidateError.invalidMLineIndex(iceCandidate.sdpMLineIndex)
        }
        
        self.id = id
        self.sdp = iceCandidate.sdp.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        self.sdpMLineIndex = iceCandidate.sdpMLineIndex
        self.sdpMid = iceCandidate.sdpMid?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }
    
    /// Converts this Swift wrapper back to a WebRTC `RTCIceCandidate`.
    ///
    /// This method safely converts the validated Swift struct back to the WebRTC type
    /// for use in WebRTC operations.
    ///
    /// - Returns: A `RTCIceCandidate` instance with the same data
    public var rtcIceCandidate: RTCIceCandidate {
        return RTCIceCandidate(sdp: self.sdp, sdpMLineIndex: self.sdpMLineIndex, sdpMid: self.sdpMid ?? "")
    }
    #endif

    // MARK: - Production Helper Methods
    
    /// Returns true if this candidate represents a local candidate.
    /// Local candidates typically have specific SDP patterns.
    public var isLocal: Bool {
        return sdp.contains("typ host") || sdp.contains("typ srflx")
    }
    
    /// Returns true if this candidate represents a relay candidate (TURN).
    /// Relay candidates are used when direct connection is not possible.
    public var isRelay: Bool {
        return sdp.contains("typ relay")
    }
    
    /// Returns the candidate type as a string for logging and debugging.
    public var candidateType: String {
        if sdp.contains("typ host") {
            return "host"
        } else if sdp.contains("typ srflx") {
            return "srflx"
        } else if sdp.contains("typ relay") {
            return "relay"
        } else if sdp.contains("typ prflx") {
            return "prflx"
        } else {
            return "unknown"
        }
    }
    
    /// Returns a human-readable description for logging purposes.
    public var description: String {
        return "IceCandidate(id: \(id), type: \(candidateType), mLineIndex: \(sdpMLineIndex), mid: \(sdpMid ?? "nil"))"
    }
}
