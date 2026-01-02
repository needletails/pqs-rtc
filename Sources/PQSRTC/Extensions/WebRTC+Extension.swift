//
//  WebRTCState+Extension.swift
//  pqs-rtc
//
//  Created by Cole M on 4/4/24.
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

/* SKIP @bridge */
/// A cross-platform wrapper around WebRTC's ICE connection state.
///
/// This type provides a stable string `description` across Apple WebRTC and Skip/Android builds,
/// which simplifies logging, comparisons, and tests.
public struct SPTIceConnectionState: Sendable, CustomStringConvertible {

    
#if !os(Android)
    /// The underlying WebRTC state value (Apple platforms only).
    public let _state: RTCIceConnectionState
    
    /// Creates a wrapper around an Apple WebRTC ICE connection state.
    public init(state: RTCIceConnectionState) {
        self._state = state
    }
    
    /// A stable string representation of the ICE connection state.
    public var description: String {
        switch _state {
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
        @unknown default:
            return "unknown"
        }
    }
    
#else
    /// A stable string representation of the ICE connection state (Skip/Android builds).
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
#if !os(Android)
        switch _state {
        case .new:
            return .new
        case .checking:
            return .checking
        case .connected:
            return .connected
        case .completed:
            return .completed
        case .failed:
            return .failed
        case .disconnected:
            return .disconnected
        case .closed:
            return .closed
        case .count:
            return .count
        @unknown default:
            return .new
        }
#else
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
#endif
    }
    
}

/* SKIP @bridge */
/// A cross-platform wrapper around WebRTC's signaling state.
///
/// The SDK primarily uses the string `description` for consistent logging and state mapping
/// across Apple WebRTC and Skip/Android builds.
public struct SPTSignalingState: Sendable, CustomStringConvertible {

    
#if !os(Android)
    /// The underlying WebRTC state value (Apple platforms only).
    public let _state: RTCSignalingState
    
    /// Creates a wrapper around an Apple WebRTC signaling state.
    public init(state: RTCSignalingState) {
        self._state = state
    }
    
    /// A stable string representation of the signaling state.
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
        @unknown default:
            return "unknown"
        }
    }
#else
    /// A stable string representation of the signaling state (Skip/Android builds).
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
#if !os(Android)
        switch _state {
        case .stable:
            return .stable
        case .haveLocalOffer:
            return .haveLocalOffer
        case .haveLocalPrAnswer:
            return .haveLocalPrAnswer
        case .haveRemoteOffer:
            return .haveRemoteOffer
        case .haveRemotePrAnswer:
            return .haveRemotePrAnswer
        case .closed:
            return .closed
        @unknown default:
            return .stable
        }
#else
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
#endif
    }
}

/* SKIP @bridge */
/// A cross-platform wrapper around WebRTC's ICE gathering state.
///
/// Exposes a stable string `description` for logging and state comparisons across Apple WebRTC and
/// Skip/Android builds.
public struct SPTIceGatheringState: Sendable, CustomStringConvertible {

    
#if !os(Android)
    /// The underlying WebRTC state value (Apple platforms only).
    public let _state: RTCIceGatheringState
    
    /// Creates a wrapper around an Apple WebRTC ICE gathering state.
    public init(state: RTCIceGatheringState) {
        self._state = state
    }
    
    /// A stable string representation of the ICE gathering state.
    public var description: String {
        switch _state {
        case .new:
            return "new"
        case .gathering:
            return "gathering"
        case .complete:
            return "complete"
        @unknown default:
            return "unknown"
        }
    }
#else
    /// A stable string representation of the ICE gathering state (Skip/Android builds).
    public var description: String = ""
#endif
    
    enum State {
        case new
        case gathering
        case complete
    }
    
    var state: State {
#if !os(Android)
        switch _state {
        case .new:
            return .new
        case .gathering:
            return .gathering
        case .complete:
            return .complete
        @unknown default:
            return .new
        }
#else
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
#endif
    }
}

/* SKIP @bridge */
/// A cross-platform wrapper around WebRTC's data-channel state.
///
/// This is primarily used for reporting `RTCDataChannel` lifecycle transitions in a
/// platform-neutral way.
public struct SPTDataChannelState: Sendable, CustomStringConvertible {

    
#if !os(Android)
    /// The underlying WebRTC state value (Apple platforms only).
    public let _state: RTCDataChannelState
    
    /// Creates a wrapper around an Apple WebRTC data channel state.
    public init(state: RTCDataChannelState) {
        self._state = state
    }
    
    /// A stable string representation of the data channel state.
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
        @unknown default:
            return "unknown"
        }
    }
#else
    /// A stable string representation of the data channel state (Skip/Android builds).
    public var description: String = ""
#endif
    
    enum State {
        case connecting
        case open
        case closing
        case closed
    }
    
    var state: State {
#if !os(Android)
        switch _state {
        case .connecting:
            return .connecting
        case .open:
            return .open
        case .closing:
            return .closing
        case .closed:
            return .closed
        @unknown default:
            return .connecting
        }
#else
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
#endif
    }
}

/* SKIP @bridge */
/// A cross-platform wrapper around WebRTC's peer-connection state.
///
/// The SDK uses this to surface connection lifecycle changes with a stable `description`, which
/// simplifies platform-neutral logging and state handling.
public struct SPTPeerConnectionState: Sendable, CustomStringConvertible {

    
#if !os(Android)
    /// The underlying WebRTC state value (Apple platforms only).
    public let _state: RTCPeerConnectionState
    
    /// Creates a wrapper around an Apple WebRTC peer-connection state.
    public init(state: RTCPeerConnectionState) {
        self._state = state
    }
    
    /// A stable string representation of the peer-connection state.
    public var description: String {
        switch _state {
        case .new:
            return "new"
        case .connecting:
            return "connecting"
        case .connected:
            return "connected"
        case .disconnected:
            return "disconnected"
        case .failed:
            return "failed"
        case .closed:
            return "closed"
        @unknown default:
            return "unknown"
        }
    }
#else
    /// A stable string representation of the peer-connection state (Skip/Android builds).
    public var description: String = ""
#endif
    
    enum State {
        case new
        case connecting
        case connected
        case disconnected
        case failed
        case closed
    }
    
    var state: State {
#if !os(Android)
        switch _state {
        case .new:
            return .new
        case .connecting:
            return .connecting
        case .connected:
            return .connected
        case .disconnected:
            return .disconnected
        case .failed:
            return .failed
        case .closed:
            return .closed
        @unknown default:
            return .new
        }
#else
        switch description {
        case "new":
            return .new
        case "connecting":
            return .connecting
        case "connected":
            return .connected
        case "disconnected":
            return .disconnected
        case "failed":
            return .failed
        case "closed":
            return .closed
        default:
            return .new
        }
#endif
    }
}
