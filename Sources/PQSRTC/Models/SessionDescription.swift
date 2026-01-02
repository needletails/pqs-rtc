//
//  SessionDescription.swift
//  pqs-rtc
//
//  Created by Cole M on 1/11/25.
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
#if !os(Android)
import WebRTC
#endif
#if SKIP
import org.webrtc.__
#endif

/// Errors that can occur during session description operations.
public enum SessionDescriptionError: Error, Sendable {
    case invalidSDP(String)
#if !os(Android)
    case unknownSdpType(WebRTC.RTCSdpType)
#elseif SKIP
    case unknownSdpType(org.webrtc.SessionDescription.`Type`)
#endif
    case conversionFailed(String)
    case invalidType(String)
    
    public var errorDescription: String? {
        switch self {
        case .invalidSDP(let message):
            return "Invalid SDP: \(message)"
#if canImport(WebRTC)
        case .unknownSdpType(let type):
            return "Unknown SDP type: \(type)"
#elseif SKIP
        case .unknownSdpType(let type):
            return "Unknown SDP type: \(type)"
#endif
        case .conversionFailed(let reason):
            return "Session description conversion failed: \(reason)"
        case .invalidType(let type):
            return "Invalid SDP type: \(type)"
        }
    }
}

/// A Swift wrapper over `RTCSessionDescription` for easy encoding and decoding.
///
/// This struct provides a safe, thread-safe interface for working with WebRTC session descriptions
/// in production environments. It includes validation and error handling for robust operation.
///
/// ## Usage
/// ```swift
/// // Create from RTCSessionDescription
/// let rtcDescription = RTCSessionDescription(type: .offer, sdp: "v=0\r\no=...")
/// let description = SessionDescription(from: rtcDescription)
///
/// // Convert back to RTCSessionDescription
/// let rtcDescription = description.rtcSessionDescription
/// ```
///
/// ## Thread Safety
/// This struct is marked as `Sendable` to ensure thread safety when used in concurrent contexts.
public struct SessionDescription: Codable, Sendable {
    
    /// The SDP (Session Description Protocol) string for this session description.
    /// Contains the complete session information including media capabilities and network details.
    public let sdp: String
    
    /// The type of this session description (offer, answer, prAnswer, or rollback).
    /// Determines the role and purpose of this description in the WebRTC negotiation process.
    public let type: SdpType
    
    #if !os(Android)
    /// Initializes a new instance of `SessionDescription` from an `RTCSessionDescription`.
    ///
    /// Creates a Swift wrapper around the WebRTC session description with validation
    /// for production safety.
    ///
    /// - Parameter rtcSessionDescription: The WebRTC session description to wrap
    ///
    /// - Throws: `SessionDescriptionError` if the description data is invalid
    public init(fromRTC rtcSessionDescription: WebRTC.RTCSessionDescription) throws {
        // Validate input parameters for production safety
        guard !rtcSessionDescription.sdp.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty else {
            throw SessionDescriptionError.invalidSDP("SDP cannot be empty")
        }
        
        self.sdp = rtcSessionDescription.sdp.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        
        // Safely convert RTCSdpType to our enum
        switch rtcSessionDescription.type {
        case RTCSdpType.offer:
            self.type = .offer
        case RTCSdpType.prAnswer:
            self.type = .prAnswer
        case RTCSdpType.answer:
            self.type = .answer
        case RTCSdpType.rollback:
            self.type = .rollback
        @unknown default:
            throw SessionDescriptionError.unknownSdpType(rtcSessionDescription.type)
        }
    }
    
    /// Converts this Swift wrapper back to a WebRTC `RTCSessionDescription`.
    ///
    /// This method safely converts the validated Swift struct back to the WebRTC type
    /// for use in WebRTC operations.
    ///
    /// - Returns: A `RTCSessionDescription` instance with the same data
    public var rtcSessionDescription: WebRTC.RTCSessionDescription {
        return WebRTC.RTCSessionDescription(type: self.type.rtcSdpType, sdp: self.sdp)
    }
    
    #elseif os(Android)
    /// Initializes a new instance of `SessionDescription` from an `RTCSessionDescription`.
    ///
    /// Creates a Swift wrapper around the WebRTC session description with validation
    /// for production safety.
    ///
    /// - Parameter rtcSessionDescription: The WebRTC session description to wrap
    ///
    /// - Throws: `SessionDescriptionError` if the description data is invalid
    public init(fromRTC rtcSessionDescription: RTCSessionDescription) throws {
        // Validate input parameters for production safety
        guard !rtcSessionDescription.sdp.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty else {
            throw SessionDescriptionError.invalidSDP("SDP cannot be empty")
        }
        
        self.sdp = rtcSessionDescription.sdp.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        self.type = .offer
#if SKIP
        // Safely convert RTCSdpType to our enum
        switch rtcSessionDescription.type {
        case org.webrtc.SessionDescription.`Type`.offer:
            self.type = .offer
        case org.webrtc.SessionDescription.`Type`.prAnswer:
            self.type = .prAnswer
        case org.webrtc.SessionDescription.`Type`.answer:
            self.type = .answer
        case org.webrtc.SessionDescription.`Type`.rollback:
            self.type = .rollback
        @unknown default:
            throw SessionDescriptionError.unknownSdpType(rtcSessionDescription.type)
        }
#endif
    }

#if SKIP
    /// Converts this Swift wrapper back to a WebRTC `RTCSessionDescription`.
    ///
    /// This method safely converts the validated Swift struct back to the WebRTC type
    /// for use in WebRTC operations.
    ///
    /// - Returns: A `RTCSessionDescription` instance with the same data
    public var rtcSessionDescription: RTCSessionDescription {
        return RTCSessionDescription(type: self.type.rtcSdpType, sdp: self.sdp)
    }
#endif
#endif
    
    // MARK: - Production Helper Methods
    
    /// Returns true if this is an offer session description.
    public var isOffer: Bool {
        return type == .offer
    }
    
    /// Returns true if this is an answer session description.
    public var isAnswer: Bool {
        return type == .answer
    }
    
    /// Returns true if this is a provisional answer session description.
    public var isPrAnswer: Bool {
        return type == .prAnswer
    }
    
    /// Returns true if this is a rollback session description.
    public var isRollback: Bool {
        return type == .rollback
    }
    
    /// Returns a human-readable description for logging purposes.
    public var description: String {
        return "SessionDescription(type: \(type.rawValue), sdpLength: \(sdp.count))"
    }
}

/// A Swift enum wrapper over `RTCSdpType` for easy encoding and decoding.
///
/// This enum provides a safe, thread-safe interface for working with WebRTC SDP types
/// in production environments. It includes validation and error handling for robust operation.
///
/// ## Usage
/// ```swift
/// let sdpType: SdpType = .offer
/// let rtcType = sdpType.rtcSdpType
/// ```
///
/// ## Thread Safety
/// This enum is marked as `Sendable` to ensure thread safety when used in concurrent contexts.
public enum SdpType: String, Codable, Sendable, CaseIterable {
    case offer = "offer"
    case prAnswer = "prAnswer"
    case answer = "answer"
    case rollback = "rollback"
    
#if SKIP
    public var rtcSdpType: org.webrtc.SessionDescription.`Type` {
        switch self {
        case .offer:
            return org.webrtc.SessionDescription.`Type`.offer
        case .prAnswer:
            return org.webrtc.SessionDescription.`Type`.prAnswer
        case .answer:
            return org.webrtc.SessionDescription.`Type`.answer
        case .rollback:
            return org.webrtc.SessionDescription.`Type`.rollback
        }
    }
#elseif !os(Android)
    public var rtcSdpType: WebRTC.RTCSdpType {
        switch self {
        case .offer:    return .offer
        case .answer:   return .answer
        case .prAnswer: return .prAnswer
        case .rollback: return .rollback
        }
    }
#endif
    /// Returns a human-readable description for logging purposes.
    public var description: String {
        return rawValue
    }
}
