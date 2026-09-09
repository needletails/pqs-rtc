import Foundation

/// Event-driven uplink yield while group SFU offer/answer/mediaReady is in flight.
///
/// UDP video can starve the TCP signaling path. Survival-class sender targets
/// apply on the 0→1 edge; the adaptive loop restores when the count returns to 0.
enum SfuSignalingUplinkYieldPolicy {
    enum Event: Equatable {
        case begin
        case completed
        case cancelled
        case failed
    }

    static func nextEssentialInFlightCount(current: Int, event: Event) -> Int {
        switch event {
        case .begin:
            return current + 1
        case .completed, .cancelled, .failed:
            return max(0, current - 1)
        }
    }

    static func shouldYield(isGroupOrConference: Bool, essentialInFlightCount: Int) -> Bool {
        isGroupOrConference && essentialInFlightCount > 0
    }

    static func shouldApplyImmediately(previousCount: Int, newCount: Int) -> Bool {
        previousCount == 0 && newCount == 1
    }
}
