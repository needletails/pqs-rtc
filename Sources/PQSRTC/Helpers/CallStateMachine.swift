//
//  CallStateMachine.swift
//  pqs-rtc
//
//  Created by Cole M on 5/16/24.
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
import NeedleTailLogger

/// An actor-backed call state machine.
///
/// `CallStateMachine` coordinates high-level call lifecycle transitions (ready → connecting →
/// connected → held/ended/failed) and exposes state updates via `AsyncStream` to support
/// concurrency-safe observation.
///
/// The state machine is used by `RTCSession` to serialize call state transitions across multiple
/// asynchronous inputs (signaling, WebRTC delegate callbacks, user actions).
public actor CallStateMachine {
    
    /// The current call direction, if known.
    ///
    /// This is set when transitioning into a state that carries direction information (for example
    /// `.connecting` or `.connected`).
    public private(set) var callDirection: CallDirection?

    /// The current call media type, if known.
    ///
    /// This is derived from `callDirection` when entering connecting/connected states.
    public private(set) var callType: CallType?

    /// The most recent state observed by the state machine.
    public private(set) var currentState: State?
    var _callType: CallType? {
        get async {
            callType
        }
    }
    
    private let logger: NeedleTailLogger
    private var pendingCall: Call?
    
    /// Continuations backing the state streams.
    ///
    /// The session yields state transitions to all continuations.
    public private(set) var streamContinuations: [AsyncStream<State>.Continuation] = []

    /// One or more streams that receive call state updates.
    ///
    /// The state machine creates multiple streams to support multiple independent consumers.
    public private(set) var currentCallStream: [AsyncStream<State>] = []
    public var _currentCallStream: [AsyncStream<State>] {
        get async {
            currentCallStream
        }
    }

    /// The current call, if one is being handled.
    public private(set) var currentCall: Call?
    
    func resetState() async {
        await cleanup()
        currentCall = nil
        pendingCall = nil
        callType = nil
        currentState = nil
        callDirection = nil

        logger.log(level: .info, message: "Call state machine reset completed")
    }
    
    init(logger: NeedleTailLogger = NeedleTailLogger("[CallState]")) {
        self.logger = logger
        logger.log(level: .debug, message: "CallStateMachine initialized")
    }
    
    deinit {
        // Synchronous cleanup in deinit
        for continuation in streamContinuations {
            continuation.finish()
        }
        streamContinuations.removeAll()
        currentCallStream.removeAll()
        self.logger.log(level: .debug, message: "Reclaimed memory in CallState")
    }
    
    private func cleanup() async {
        for continuation in streamContinuations {
            continuation.finish()
        }
        streamContinuations.removeAll()
        currentCallStream.removeAll()
        logger.log(level: .debug, message: "CallStateMachine cleanup completed")
    }
    
    func createStreams(with call: Call) async {
        // Clean up existing streams first
        await cleanup()
        
        logger.log(level: .info, message: "Creating streams for call: \(call.sharedCommunicationId)")
        
        let logger = self.logger
        currentCallStream.append(contentsOf: [
            AsyncStream<State>(bufferingPolicy: AsyncStream<State>.Continuation.BufferingPolicy.bufferingNewest(1)) { continuation in
                streamContinuations.append(continuation)
                continuation.onTermination = { status in
                    logger.log(level: .debug, message: "Call State Stream Terminated with status: \(status)")
                }
            },
            AsyncStream<State>(bufferingPolicy: AsyncStream<State>.Continuation.BufferingPolicy.bufferingNewest(1)) { continuation in
                streamContinuations.append(continuation)
                continuation.onTermination = { status in
                    logger.log(level: .debug, message: "Call State Stream Terminated with status: \(status)")
                }
            }
        ])
        await self.transition(to: .ready(call))
    }
    
    /// The media type of a call.
    public enum CallType: Codable, Sendable, Equatable {
        case voice, video
        
        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let stringValue = try container.decode(String.self)
            switch stringValue {
            case "voice": self = .voice
            case "video": self = .video
            default: throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid CallType: \(stringValue)")
            }
        }
        
        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .voice: try container.encode("voice")
            case .video: try container.encode("video")
            }
        }
    }
    /// Whether a call is inbound or outbound, and its media type.
    public enum CallDirection: Codable, Sendable, Equatable {
        case inbound(CallType), outbound(CallType)
        
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let callType = try container.decodeIfPresent(CallType.self, forKey: CodingKeys.inbound) {
                self = .inbound(callType)
            } else if let callType = try container.decodeIfPresent(CallType.self, forKey: CodingKeys.outbound) {
                self = .outbound(callType)
            } else {
                throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: container.codingPath, debugDescription: "Invalid CallDirection"))
            }
        }
        
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .inbound(let callType): try container.encode(callType, forKey: CodingKeys.inbound)
            case .outbound(let callType): try container.encode(callType, forKey: CodingKeys.outbound)
            }
        }
        
        private enum CodingKeys: String, CodingKey {
            case inbound, outbound
        }
    }
    
    /// High-level reason a call ended.
    public enum EndState: Codable, Sendable {
        case userInitiated, partnerInitiated, userInitiatedUnanswered, partnerInitiatedUnanswered, partnerInitiatedRejected, failed, auxialaryDevcieAnswered
        
        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let stringValue = try container.decode(String.self)
            switch stringValue {
            case "userInitiated": self = .userInitiated
            case "partnerInitiated": self = .partnerInitiated
            case "userInitiatedUnanswered": self = .userInitiatedUnanswered
            case "partnerInitiatedUnanswered": self = .partnerInitiatedUnanswered
            case "partnerInitiatedRejected": self = .partnerInitiatedRejected
            case "failed": self = .failed
            case "auxialaryDevcieAnswered": self = .auxialaryDevcieAnswered
            default: throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid EndState: \(stringValue)")
            }
        }
        
        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .userInitiated: try container.encode("userInitiated")
            case .partnerInitiated: try container.encode("partnerInitiated")
            case .userInitiatedUnanswered: try container.encode("userInitiatedUnanswered")
            case .partnerInitiatedUnanswered: try container.encode("partnerInitiatedUnanswered")
            case .partnerInitiatedRejected: try container.encode("partnerInitiatedRejected")
            case .failed: try container.encode("failed")
            case .auxialaryDevcieAnswered: try container.encode("auxialaryDevcieAnswered")
            }
        }
    }
    
    /// A call lifecycle state.
    ///
    /// Most cases carry the associated `Call` and (when applicable) the call direction.
    public enum State: Codable, Sendable, Equatable {
        case waiting, ready(Call), connecting(CallDirection, Call), connected(CallDirection, Call), held(CallDirection?, Call), ended(EndState, Call), failed(CallDirection?, Call, String), callAnsweredAuxDevice(Call)
        
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: CodingKeys.type)
            
            switch type {
            case "waiting":
                self = .waiting
            case "ready":
                let call = try container.decode(Call.self, forKey: CodingKeys.call)
                self = .ready(call)
            case "connecting":
                let direction = try container.decode(CallDirection.self, forKey: CodingKeys.direction)
                let call = try container.decode(Call.self, forKey: CodingKeys.call)
                self = .connecting(direction, call)
            case "connected":
                let direction = try container.decode(CallDirection.self, forKey: CodingKeys.direction)
                let call = try container.decode(Call.self, forKey: CodingKeys.call)
                self = .connected(direction, call)
            case "held":
                let direction = try container.decodeIfPresent(CallDirection.self, forKey: CodingKeys.direction)
                let call = try container.decode(Call.self, forKey: CodingKeys.call)
                self = .held(direction, call)
            case "ended":
                let endState = try container.decode(EndState.self, forKey: CodingKeys.endState)
                let call = try container.decode(Call.self, forKey: CodingKeys.call)
                self = .ended(endState, call)
            case "failed":
                let direction = try container.decodeIfPresent(CallDirection.self, forKey: CodingKeys.direction)
                let call = try container.decode(Call.self, forKey: CodingKeys.call)
                let errorMessage = try container.decode(String.self, forKey: CodingKeys.errorMessage)
                self = .failed(direction, call, errorMessage)
            case "callAnsweredAuxDevice":
                let call = try container.decode(Call.self, forKey: CodingKeys.call)
                self = .callAnsweredAuxDevice(call)
            default:
                throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: container.codingPath, debugDescription: "Invalid State type: \(type)"))
            }
        }
        
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            
            switch self {
            case .waiting:
                try container.encode("waiting", forKey: CodingKeys.type)
            case .ready(let call):
                try container.encode("ready", forKey: CodingKeys.type)
                try container.encode(call, forKey: CodingKeys.call)
            case .connecting(let direction, let call):
                try container.encode("connecting", forKey: CodingKeys.type)
                try container.encode(direction, forKey: CodingKeys.direction)
                try container.encode(call, forKey: CodingKeys.call)
            case .connected(let direction, let call):
                try container.encode("connected", forKey: CodingKeys.type)
                try container.encode(direction, forKey: CodingKeys.direction)
                try container.encode(call, forKey: CodingKeys.call)
            case .held(let direction, let call):
                try container.encode("held", forKey: CodingKeys.type)
                try container.encodeIfPresent(direction, forKey: CodingKeys.direction)
                try container.encode(call, forKey: CodingKeys.call)
            case .ended(let endState, let call):
                try container.encode("ended", forKey: CodingKeys.type)
                try container.encode(endState, forKey: CodingKeys.endState)
                try container.encode(call, forKey: CodingKeys.call)
            case .failed(let direction, let call, let errorMessage):
                try container.encode("failed", forKey: CodingKeys.type)
                try container.encodeIfPresent(direction, forKey: CodingKeys.direction)
                try container.encode(call, forKey: CodingKeys.call)
                try container.encode(errorMessage, forKey: CodingKeys.errorMessage)
            case .callAnsweredAuxDevice(let call):
                try container.encode("callAnsweredAuxDevice", forKey: CodingKeys.type)
                try container.encode(call, forKey: CodingKeys.call)
            }
        }
        
        private enum CodingKeys: String, CodingKey {
            case type, call, direction, endState, errorMessage
        }
    }
    
    /// Transitions the state machine to `nextState` and yields the update to all active streams.
    ///
    /// If the machine is already in `nextState`, the transition is skipped.
    ///
    /// - Parameter nextState: The next state to enter.
    public func transition(to nextState: State) async {
        if currentState == nextState { 
            logger.log(level: .debug, message: "State transition skipped - already in state: \(nextState)")
            return 
        }
        
        let previousState = currentState
        currentState = nextState
        
        switch nextState {
        case .waiting:
            self.logger.log(level: .info, message: "Waiting To Initialize Call")
        case .ready(let call):
            self.logger.log(level: .info, message: "Ready To Initialize Call: \(call.sharedCommunicationId)")
        case .connecting(let callDirection, let currentCall):
            self.callDirection = callDirection
            self.currentCall = currentCall
            switch callDirection {
            case .inbound(let type):
                callType = type
                self.logger.log(level: .info, message: "Inbound \(type) Call Received, Connecting... Call ID: \(currentCall.sharedCommunicationId)")
            case .outbound(let type):
                callType = type
                self.logger.log(level: .info, message: "Outbound \(type) Call Made, Connecting... Call ID: \(currentCall.sharedCommunicationId)")
            }
        case .connected(let callDirection, let pendingCall):
            self.pendingCall = pendingCall
            switch callDirection {
            case .inbound(let type):
                callType = type
                self.logger.log(level: .info, message: "Connected Inbound \(type) Call: \(pendingCall.sharedCommunicationId)")
            case .outbound(let type):
                callType = type
                self.logger.log(level: .info, message: "Connected Outbound \(type) Call: \(pendingCall.sharedCommunicationId)")
            }
        case .held(let direction, let call):
            let directionString = direction?.description ?? "unknown"
            self.logger.log(level: .info, message: "Held \(directionString) Call: \(call.id)")
        case .ended(let endState, let call):
            self.logger.log(level: .info, message: "Ended Call in state \(endState) for call: \(call.sharedCommunicationId)")
        case .failed(let direction, let call, let error):
            let directionString = direction?.description ?? "unknown"
            self.logger.log(level: .error, message: "Call Failed with error: \(error) for \(directionString) call: \(call.sharedCommunicationId)")
        case .callAnsweredAuxDevice(let call):
            self.logger.log(level: .info, message: "Call Answered by other device: \(call.sharedCommunicationId)")
        }
        
        // Yield to all continuations with error handling
        for continuation in streamContinuations {
            continuation.yield(nextState)
        }
        
        logger.log(level: .info, message: "State transition completed: \(previousState?.description ?? "nil") -> \(nextState)")
    }
}

// MARK: - Extensions for better debugging
extension CallStateMachine.CallType: CustomStringConvertible {
    public var description: String {
        switch self {
        case .voice: return "Voice"
        case .video: return "Video"
        }
    }
}

extension CallStateMachine.CallDirection: CustomStringConvertible {
    public var description: String {
        switch self {
        case .inbound(let type): return "Inbound \(type)"
        case .outbound(let type): return "Outbound \(type)"
        }
    }
}

extension CallStateMachine.State: CustomStringConvertible {
    public var description: String {
        switch self {
        case .waiting: return "Waiting"
        case .ready(let call): return "Ready(\(call.sharedCommunicationId))"
        case .connecting(let direction, let call): return "Connecting(\(direction), \(call.sharedCommunicationId))"
        case .connected(let direction, let call): return "Connected(\(direction), \(call.sharedCommunicationId))"
        case .held(let direction, let call): return "Held(\(direction?.description ?? "nil"), \(call.sharedCommunicationId))"
        case .ended(let endState, let call): return "Ended(\(endState), \(call.id))"
        case .failed(let direction, let call, let error): return "Failed(\(direction?.description ?? "nil"), \(call.sharedCommunicationId), \(error))"
        case .callAnsweredAuxDevice(let call): return "CallAnsweredAuxDevice(\(call.sharedCommunicationId))"
        }
    }
}
