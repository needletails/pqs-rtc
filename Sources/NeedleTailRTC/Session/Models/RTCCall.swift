//
//  RTCCall.swift
//  needle-tail-rtc
//
//  Created by Cole M on 10/4/25.
//
import Foundation


public struct RTCCall: Codable, Sendable {
    public var sdp: SessionDescription?
    public var candidate: IceCandidate?
    public var endState: CallStateMachine.EndState?
    public var call: Call
    
    public init(
        sdp: SessionDescription? = nil,
        candidate: IceCandidate? = nil,
        endState: CallStateMachine.EndState? = nil,
        call: Call
    ) {
        self.sdp = sdp
        self.candidate = candidate
        self.endState = endState
        self.call = call
    }
}
