//
//  RTCNetworkQualityUpdate.swift
//  pqs-rtc
//
//  A minimal, UI-agnostic signal for "network is struggling / recovered".
//

import Foundation

/// Coarse network quality buckets intended for UI decisions.
///
/// These are deliberately *not* tied to a specific UI. Consumers can map buckets to banners,
/// icons, or adaptive UX (e.g. offer audio-only).
public enum RTCNetworkQuality: String, Sendable, Equatable {
    case excellent
    case good
    case fair
    case poor
    case veryPoor
}

/// Snapshot emitted when the SDK believes network conditions have materially changed.
public struct RTCNetworkQualityUpdate: Sendable, Equatable {
    /// Connection identifier the quality pertains to (typically `call.sharedCommunicationId`).
    public let connectionId: String
    public let quality: RTCNetworkQuality

    /// Selected ICE candidate pair's `availableOutgoingBitrate` (bps), if available.
    public let availableOutgoingBitrateBps: Int?

    /// Selected ICE candidate pair RTT (ms), if available.
    public let rttMs: Int?

    /// Current ceilings the SDK is applying to the local video sender (SFU/group calls),
    /// if applicable.
    public let appliedVideoMaxBitrateBps: Int?
    public let appliedVideoMaxFramerate: Int?

    /// Monotonic-ish timestamp for correlation (wall clock).
    public let timestamp: Date

    public init(
        connectionId: String,
        quality: RTCNetworkQuality,
        availableOutgoingBitrateBps: Int?,
        rttMs: Int?,
        appliedVideoMaxBitrateBps: Int?,
        appliedVideoMaxFramerate: Int?,
        timestamp: Date = Date()
    ) {
        self.connectionId = connectionId
        self.quality = quality
        self.availableOutgoingBitrateBps = availableOutgoingBitrateBps
        self.rttMs = rttMs
        self.appliedVideoMaxBitrateBps = appliedVideoMaxBitrateBps
        self.appliedVideoMaxFramerate = appliedVideoMaxFramerate
        self.timestamp = timestamp
    }
}

