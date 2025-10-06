//
//  WebRTCState+Extension.swift
//  needle-tail-rtc
//
//  Created by Cole M on 4/4/24.
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

public struct SPTIceConnectionState: Sendable, CustomStringConvertible {
    
#if !os(Android)
    public let _state: RTCIceConnectionState
    
    public init(state: RTCIceConnectionState) {
        self._state = state
    }
    
    public var description: String {
        switch state {
        case .new:
            return "new"
        case .checking:
            return "checking"
        case .connected:
            return "connected"
        case .completed:
            return "completed"
        case .failed:
            return "failed"
        case .disconnected:
            return "disconnected"
        case .closed:
            return "closed"
        case .count:
            return "count"
        }
    }
    
#else
    public var description: String = ""
#endif
    
    enum State {
        case new
        case checking
        case connected
        case completed
        case failed
        case disconnected
        case closed
        case count
    }
    
    var state: State {
        switch description {
        case "new":
            return .new
        case "checking":
            return .checking
        case "connected":
            return .connected
        case "completed":
            return .completed
        case "failed":
            return .failed
        case "disconnected":
            return .disconnected
        case "closed":
            return .closed
        case "count":
            return .count
        default:
            return .new
        }
    }
    
}

public struct SPTSignalingState: Sendable, CustomStringConvertible {
    
#if !os(Android)
    public let _state: RTCSignalingState
    
    public init(state: RTCSignalingState) {
        self._state = state
    }
    
    public var description: String {
        switch _state {
        case .stable:
            return "stable"
        case .haveLocalOffer:
            return "haveLocalOffer"
        case .haveLocalPrAnswer:
            return "haveLocalPrAnswer"
        case .haveRemoteOffer:
            return "haveRemoteOffer"
        case .haveRemotePrAnswer:
            return "haveRemotePrAnswer"
        case .closed:
            return "closed"
        default:
            return "Unknown \(state)"
        }
    }
#else
    public var description: String = ""
#endif
    
    enum State {
        case stable
        case haveLocalOffer
        case haveLocalPrAnswer
        case haveRemoteOffer
        case haveRemotePrAnswer
        case closed
    }
    
    var state: State {
        switch description {
        case "stable":
            return .stable
        case "haveLocalOffer":
            return .haveLocalOffer
        case "haveLocalPrAnswer":
            return .haveLocalPrAnswer
        case "haveRemoteOffer":
            return .haveRemoteOffer
        case "haveRemotePrAnswer":
            return .haveRemotePrAnswer
        case "closed":
            return .closed
        default:
            return .stable
        }
    }
}

public struct SPTIceGatheringState: Sendable, CustomStringConvertible {
    
#if !os(Android)
    public let _state: RTCIceGatheringState
    
    public init(state: RTCIceGatheringState) {
        self._state = state
    }
    
    public var description: String {
        switch _state {
        case .new:
            return "new"
        case .gathering:
            return "gathering"
        case .complete:
            return "complete"
        default:
            return "Unknown \(state)"
        }
    }
#else
    public var description: String = ""
#endif
    
    enum State {
        case new
        case gathering
        case complete
    }
    
    var state: State {
        switch description {
        case "new":
            return .new
        case "gathering":
            return .gathering
        case "complete":
            return .complete
        default:
            return .new
        }
    }
}

public struct SPTDataChannelState: Sendable, CustomStringConvertible {
    
#if !os(Android)
    public let _state: RTCDataChannelState
    
    public init(state: RTCDataChannelState) {
        self._state = state
    }
    
    public var description: String {
        switch _state {
        case .connecting:
            return "connecting"
        case .open:
            return "open"
        case .closing:
            return "closing"
        case .closed:
            return "closed"
        default:
            return "Unknown \(state)"
        }
    }
#else
    public var description: String = ""
#endif
    
    enum State {
        case connecting
        case open
        case closing
        case closed
    }
    
    var state: State {
        switch description {
        case "connecting":
            return .connecting
        case "open":
            return .open
        case "closing":
            return .closing
        case "closed":
            return .closed
        default:
            return .connecting
        }
    }
}
