//
//  PeerConnectionNotifications.swift
//  needle-tail-rtc
//
//  Created by Cole M on 10/4/25.
//
import Foundation

public enum PeerConnectionNotifications: Sendable {
    case iceGatheringDidChange(String, SPTIceGatheringState)
    case signalingStateDidChange(String, SPTSignalingState)
    case addedStream(String, String)
    case removedStream(String, String)
    case iceConnectionStateDidChange(String, SPTIceConnectionState)
    case generatedIceCandidate(String, String, Int32, String?)
    case standardizedIceConnectionState(String, SPTIceConnectionState)
    case removedIceCandidates(String, Int)
    case startedReceiving(String, String)
    case dataChannel(String, String)
    case shouldNegotiate(String)
}
