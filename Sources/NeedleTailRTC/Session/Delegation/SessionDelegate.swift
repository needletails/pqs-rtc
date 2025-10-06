//
//  SessionDelegate.swift
//  needle-tail-rtc
//
//  Created by Cole M on 10/4/25.
//


public protocol SessionDelegate: AnyObject, Sendable {
    var calls: [Call] { get async }
    func sendCandidate(_ candidate: IceCandidate, call: Call) async throws
    func invokeEnd(call: Call, endState: CallStateMachine.EndState) async throws
    func sendUpDowngrade(to call: RTCCall, isUpgrade: Bool) async throws
    func sendHoldCallMessage(to call: Call) async
    func updateMetadata(for call: Call, callState: CallStateMachine.State) async
}
