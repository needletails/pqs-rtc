//
//  Call.swift
//  pqs-rtc
//
//  Created by Cole M on 6/30/25.
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
import DoubleRatchetKit

/// A structure representing metadata for SDP (Session Description Protocol) negotiation.
///
/// This struct contains information about the participants involved in WebRTC session
/// negotiation, including the offer and answer devices. It's used for establishing
/// secure peer-to-peer connections for voice and video calls.
///
/// ## Usage
/// ```swift
/// let sdpMetadata = SDPNegotiationMetadata(
///     offerSecretName: "alice_secure",
///     offerDeviceId: "device_123",
///     answerDeviceId: "device_456"
/// )
/// ```
///
/// ## Properties
/// - `offerSecretName`: The secret name associated with the participant making the offer
/// - `offerDeviceId`: The device ID of the participant making the offer
/// - `answerDeviceId`: The device ID of the participant answering the offer
///
/// ## WebRTC Integration
/// This metadata is used in conjunction with WebRTC to establish secure peer-to-peer
/// connections for real-time communication features.
public struct SDPNegotiationMetadata: Codable, Sendable, Equatable {
    /// The secret name associated with the offer.
    /// Used to identify the participant making the WebRTC offer.
    public let offerSecretName: String
    
    /// The device ID of the participant making the offer.
    /// Identifies the specific device initiating the connection.
    public let offerDeviceId: String
    
    /// The device ID of the participant answering the offer.
    /// Identifies the specific device accepting the connection.
    public let answerDeviceId: String
    
    /// Initializes a new instance of `SDPNegotiationMetadata`.
    ///
    /// Creates SDP negotiation metadata with the specified participant information.
    ///
    /// - Parameters:
    ///   - offerSecretName: The secret name of the participant making the offer
    ///   - offerDeviceId: The device ID of the participant making the offer
    ///   - answerDeviceId: The device ID of the participant answering the offer
    ///
    /// - Throws: `CallError.invalidMetadata` if any required parameter is empty
    public init(
        offerSecretName: String,
        offerDeviceId: String,
        answerDeviceId: String
    ) throws {
        // Validate input parameters for production safety
        guard !offerSecretName.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty else {
            throw CallError.invalidMetadata("offerSecretName cannot be empty")
        }
        guard !offerDeviceId.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty else {
            throw CallError.invalidMetadata("offerDeviceId cannot be empty")
        }
        
        self.offerSecretName = offerSecretName.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        self.offerDeviceId = offerDeviceId.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        self.answerDeviceId = answerDeviceId.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }
}

/// A structure representing metadata for starting a call.
///
/// This struct contains comprehensive information about the participants involved in a call
/// and other relevant metadata needed to establish the communication session. It's used
/// for both voice and video calls.
///
/// ## Usage
/// ```swift
/// let callMetadata = StartCallMetadata(
///     sharedMessageId: "msg_789",
///     answerParticipant: nil
/// )
/// ```
///
/// ## Properties
///   - `answerParticipant`: The participant answering the call (optional for group calls)
///   - `sharedMessageId`: An optional identifier for a shared message related to the call
public struct StartCallMetadata: Codable, Sendable, Equatable {
    
    /// The participant making the call offer.
    /// Contains the secret name, nickname, and device ID of the caller.
    public var offerParticipant: Call.Participant
    
    /// The participant answering the call (optional).
    /// For group calls, this may be nil as multiple participants can answer.
    public var answerParticipant: Call.Participant?
    
    /// An optional identifier for a shared message related to the call.
    /// Used to associate the call with a specific message or conversation thread.
    public var sharedMessageId: String?
    
    /// A unique identifier for the communication session.
    /// Used to track and manage the call throughout its lifecycle.
    public let communicationId: String
    
    /// A boolean indicating whether video is supported for the call.
    /// Determines if the call will be audio-only or include video capabilities.
    public let supportsVideo: Bool
    
    /// Initializes a new instance of `StartCallMetadata`.
    ///
    /// Creates call metadata with the specified participant information and call settings.
    ///
    /// - Parameters:
    ///   - offerParticipant: The participant making the call offer
    ///   - answerParticipant: The participant answering the call (optional for group calls)
    ///   - sharedMessageId: An optional identifier for a shared message related to the call
    ///   - communicationId: A unique identifier for the communication session
    ///   - supportsVideo: A boolean indicating whether video is supported for the call
    ///
    /// - Throws: `CallError.invalidMetadata` if required parameters are invalid
    public init(
        offerParticipant: Call.Participant,
        answerParticipant: Call.Participant? = nil,
        sharedMessageId: String? = nil,
        communicationId: String,
        supportsVideo: Bool
    ) throws {
        // Validate input parameters for production safety
        guard !communicationId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CallError.invalidMetadata("communicationId cannot be empty")
        }
        
        self.offerParticipant = offerParticipant
        self.answerParticipant = answerParticipant
        self.sharedMessageId = sharedMessageId?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.communicationId = communicationId.trimmingCharacters(in: .whitespacesAndNewlines)
        self.supportsVideo = supportsVideo
    }
}

/// Errors that can occur during call operations.
public enum CallError: Error, Sendable {
    case invalidMetadata(String)
    case invalidParticipant(String)
    case callNotFound(UUID)
    case callAlreadyActive(UUID)
    case callExpired(UUID)
    
    public var errorDescription: String? {
        switch self {
        case .invalidMetadata(let message):
            return "Invalid call metadata: \(message)"
        case .invalidParticipant(let message):
            return "Invalid participant: \(message)"
        case .callNotFound(let id):
            return "Call not found with ID: \(id)"
        case .callAlreadyActive(let id):
            return "Call already active with ID: \(id)"
        case .callExpired(let id):
            return "Call expired with ID: \(id)"
        }
    }
}

/// A structure representing a call object for voice and video communication.
///
/// A session can have many calls, including current, previous, and on-hold calls. Each call
/// object contains comprehensive information about the communication session, participants,
/// timing, and status. Calls can be encoded into data and stored in base communication metadata.
///
/// ## Usage
/// ```swift
/// let call = Call(
///     sharedCommunicationId: "comm_123",
///     sender: Call.Participant(
///         secretName: "alice_secure",
///         nickname: "Alice",
///         deviceId: "device_123"
///     ),
///     recipients: [
///         Call.Participant(
///             secretName: "bob_secure",
///             nickname: "Bob",
///             deviceId: "device_456"
///         )
///     ],
///     supportsVideo: true,
///     isActive: true
/// )
/// ```
///
/// ## Properties
/// - `id`: A unique identifier for the call, used for tracking and management
/// - `sharedMessageId`: An optional identifier for a shared message related to the call
/// - `sharedCommunicationId`: A unique identifier for the shared communication session
/// - `sender`: The participant who initiated the call
/// - `recipients`: An array of participants who are receiving the call
/// - `createdAt`: The date and time when the call was created
/// - `updatedAt`: An optional date and time when the call was last updated
/// - `endedAt`: An optional date and time when the call ended
/// - `supportsVideo`: A boolean indicating whether the call supports video
/// - `unanswered`: An optional boolean indicating whether the call was unanswered
/// - `rejected`: An optional boolean indicating whether the call was rejected
/// - `failed`: An optional boolean indicating whether the call failed
/// - `isActive`: A boolean indicating whether the call is currently active
/// - `metadata`: Additional metadata associated with the call, stored as a Foundation Data
///
/// ## Call States
/// The call can be in various states represented by the boolean flags:
/// - `isActive`: Currently ongoing
/// - `unanswered`: Call was not answered by recipients
/// - `rejected`: Call was explicitly rejected
/// - `failed`: Call failed due to technical issues
public struct Call: Sendable, Codable, Equatable {
    
    /// A structure representing the properties of a call for secure storage.
    ///
    /// This struct is used internally for encrypting and storing call data securely.
    /// It contains the call's unique identifier and encrypted data.
    public struct Props: Sendable, Codable {
        /// The unique identifier for the call.
        public var id: UUID
        
        /// The encrypted data containing the call information.
        public var data: Data
        
        /// Initializes a new instance of `Props`.
        ///
        /// - Parameters:
        ///   - id: The unique identifier for the call
        ///   - data: The encrypted data containing call information
        public init(id: UUID, data: Data) {
            self.id = id
            self.data = data
        }
    }
    
    /// A structure representing a participant in a call.
    ///
    /// Contains information about a participant including their secret name for identification,
    /// nickname for display, and device ID for routing.
    ///
    /// ## Properties
    /// - `secretName`: The secret name of the participant, used for secure identification
    /// - `nickname`: The nickname of the participant, used for display purposes
    /// - `deviceId`: The device ID of the participant, used for message routing
    public struct Participant: Sendable, Codable, Equatable {
        /// The secret name of the participant.
        /// Used for secure identification in the communication system.
        public let secretName: String
        
        /// The nickname of the participant.
        /// Used for display purposes in the user interface.
        public let nickname: String
        
        /// The device ID of the participant.
        /// Used for routing messages and establishing connections.
        public var deviceId: String
        
        /// Initializes a new instance of `Participant`.
        ///
        /// Creates a participant with the specified identification information.
        ///
        /// - Parameters:
        ///   - secretName: The secret name of the participant for secure identification
        ///   - nickname: The nickname of the participant for display purposes
        ///   - deviceId: The device ID of the participant for message routing
        ///
        /// - Throws: `CallError.invalidParticipant` if any required parameter is empty
        public init(secretName: String, nickname: String, deviceId: String) throws {
            // Validate input parameters for production safety
            guard !secretName.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty else {
                throw CallError.invalidParticipant("secretName cannot be empty")
            }
            guard !nickname.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty else {
                throw CallError.invalidParticipant("nickname cannot be empty")
            }
            
            self.secretName = secretName.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            self.nickname = nickname.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            self.deviceId = deviceId.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        }
    }
    
    /// A unique identifier for the call.
    /// Used for tracking, management, and correlation of call-related events.
    public var id: UUID
    
    /// An optional identifier for a shared message related to the call.
    /// Used to associate the call with a specific message or conversation thread.
    public var sharedMessageId: String?
    
    /// A unique identifier for the shared communication session.
    /// Used to group related calls and manage the overall communication session.
    public var sharedCommunicationId: String
    
    /// The participant who initiated the call.
    /// Contains the caller's identification and device information.
    public var sender: Participant
    
    /// An array of participants who are receiving the call.
    /// Can contain multiple participants for group calls.
    public var recipients: [Participant]
    
    /// The date and time when the call was created.
    /// Used for call history and timing calculations.
    public var createdAt: Date
    
    /// An optional date and time when the call was last updated.
    /// Used for tracking call state changes and modifications.
    public var updatedAt: Date?
    
    /// An optional date and time when the call ended.
    /// Used for call duration calculations and history.
    public var endedAt: Date?
    
    /// A boolean indicating whether the call supports video.
    /// Determines if the call is audio-only or includes video capabilities.
    public var supportsVideo: Bool
    
    /// An optional boolean indicating whether the call was unanswered.
    /// Set to true if no recipient answered the call.
    public var unanswered: Bool?
    
    /// An optional boolean indicating whether the call was rejected.
    /// Set to true if a recipient explicitly rejected the call.
    public var rejected: Bool?
    
    /// An optional boolean indicating whether the call failed.
    /// Set to true if the call failed due to technical issues.
    public var failed: Bool?
    
    /// A boolean indicating whether the call is currently active.
    /// Used to determine the current state of the call.
    public var isActive: Bool
    
    /// RTC Frame Props
    public var frameIdentityProps: SessionIdentity.UnwrappedProps?
    
    ///Signalling props
    public var signalingIdentityProps: SessionIdentity.UnwrappedProps?
    
    /// Additional metadata associated with the call.
    /// Stored as a Foundation Data
    public var metadata: Data?
    
    /// Initializes a new instance of `Call`.
    ///
    /// Creates a call with the specified parameters. Many parameters have sensible defaults
    /// to simplify call creation while maintaining flexibility.
    ///
    /// - Parameters:
    ///   - id: A unique identifier for the call (defaults to a new UUID)
    ///   - sharedMessageId: An optional identifier for a shared message related to the call
    ///   - sharedCommunicationId: A unique identifier for the shared communication session
    ///   - sender: The participant who initiated the call
    ///   - recipients: An array of participants who are receiving the call
    ///   - createdAt: The date and time when the call was created (defaults to the current date)
    ///   - updatedAt: An optional date and time when the call was last updated
    ///   - endedAt: An optional date and time when the call ended
    ///   - supportsVideo: A boolean indicating whether the call supports video (defaults to false)
    ///   - unanswered: An optional boolean indicating whether the call was unanswered
    ///   - rejected: An optional boolean indicating whether the call was rejected
    ///   - failed: An optional boolean indicating whether the call failed
    ///   - isActive: A boolean indicating whether the call is currently active (defaults to false)
    ///   - metadata: Additional metadata associated with the call
    ///
    /// - Throws: `CallError.invalidMetadata` if required parameters are invalid
    public init(
        id: UUID = UUID(),
        sharedMessageId: String? = nil,
        sharedCommunicationId: String,
        sender: Participant,
        recipients: [Participant],
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        endedAt: Date? = nil,
        supportsVideo: Bool = false,
        unanswered: Bool? = nil,
        rejected: Bool? = nil,
        failed: Bool? = nil,
        isActive: Bool = false,
        frameIdentityProps: SessionIdentity.UnwrappedProps? = nil,
        signalingIdentityProps: SessionIdentity.UnwrappedProps? = nil,
        metadata: Data? = nil
    ) throws {
        // Validate input parameters for production safety
        guard !sharedCommunicationId.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty else {
            throw CallError.invalidMetadata("sharedCommunicationId cannot be empty")
        }
        guard !recipients.isEmpty else {
            throw CallError.invalidMetadata("recipients cannot be empty")
        }
        
        self.id = id
        self.sharedMessageId = sharedMessageId?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        self.sharedCommunicationId = sharedCommunicationId.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        self.sender = sender
        self.recipients = recipients
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.endedAt = endedAt
        self.supportsVideo = supportsVideo
        self.unanswered = unanswered
        self.rejected = rejected
        self.failed = failed
        self.isActive = isActive
        self.frameIdentityProps = frameIdentityProps
        self.signalingIdentityProps = signalingIdentityProps
        self.metadata = metadata
    }

    /// Initializes a `Call` intended for SFU/group-call usage.
    ///
    /// Unlike the primary initializer, this initializer **allows empty `recipients`** so an SFU room
    /// can be joined before any remote participants are known.
    ///
    /// - Important: For 1:1 calls, prefer the primary initializer which enforces `recipients` is non-empty.
    public init(
        groupSharedCommunicationId: String,
        sender: Participant,
        recipients: [Participant] = [],
        supportsVideo: Bool = false,
        isActive: Bool = false,
        frameIdentityProps: SessionIdentity.UnwrappedProps? = nil,
        signalingIdentityProps: SessionIdentity.UnwrappedProps? = nil,
        metadata: Data? = nil
    ) throws {
        let trimmed = groupSharedCommunicationId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CallError.invalidMetadata("sharedCommunicationId cannot be empty")
        }

        self.id = UUID()
        self.sharedMessageId = nil
        self.sharedCommunicationId = trimmed
        self.sender = sender
        self.recipients = recipients
        self.createdAt = Date()
        self.updatedAt = nil
        self.endedAt = nil
        self.supportsVideo = supportsVideo
        self.unanswered = nil
        self.rejected = nil
        self.failed = nil
        self.isActive = isActive
        self.frameIdentityProps = frameIdentityProps
        self.signalingIdentityProps = signalingIdentityProps
        self.metadata = metadata
    }
    
    // MARK: - Production Helper Methods
    
    /// Returns the duration of the call in seconds.
    /// Returns nil if the call hasn't ended yet.
    public var duration: TimeInterval? {
        guard let endedAt = endedAt else { return nil }
        return endedAt.timeIntervalSince(createdAt)
    }
    
    /// Returns true if the call has ended (either successfully or with an error).
    public var hasEnded: Bool {
        return endedAt != nil || failed == true || rejected == true || unanswered == true
    }
    
    /// Returns true if the call is in a terminal state.
    public var isTerminal: Bool {
        return hasEnded || !isActive
    }
    
    /// Updates the call state to mark it as ended.
    /// - Parameter endState: The state in which the call ended
    public mutating func endCall(endState: EndState) {
        self.endedAt = Date()
        self.isActive = false
        
        switch endState {
        case .answered:
            // Call was answered and completed normally
            break
        case .unanswered:
            self.unanswered = true
        case .rejected:
            self.rejected = true
        case .failed:
            self.failed = true
        }
    }
    
    /// Represents the end state of a call.
    public enum EndState: String, Codable, Sendable {
        case answered = "answered"
        case unanswered = "unanswered"
        case rejected = "rejected"
        case failed = "failed"
    }
}

extension SessionIdentity.UnwrappedProps: @retroactive Equatable {
    public static func == (lhs: DoubleRatchetKit.SessionIdentity.UnwrappedProps, rhs: DoubleRatchetKit.SessionIdentity.UnwrappedProps) -> Bool {
        lhs.deviceId == rhs.deviceId
    }
}
