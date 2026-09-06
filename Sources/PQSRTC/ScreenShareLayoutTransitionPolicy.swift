import Foundation

public enum ScreenShareLayoutTransitionPhase: Equatable, Sendable {
    case idle
    case awaitingStartLayout(generation: UInt64)
    case active
    case awaitingStopLayout(generation: UInt64)
}

public struct ScreenShareLayoutTransitionState: Equatable, Sendable {
    public var phase: ScreenShareLayoutTransitionPhase
    public var generation: UInt64
    public var expectedIdentities: Set<String>
    public var reportedIdentities: Set<String>

    public init(
        phase: ScreenShareLayoutTransitionPhase = .idle,
        generation: UInt64 = 0,
        expectedIdentities: Set<String> = [],
        reportedIdentities: Set<String> = []
    ) {
        self.phase = phase
        self.generation = generation
        self.expectedIdentities = expectedIdentities
        self.reportedIdentities = reportedIdentities
    }

    public static let idle = ScreenShareLayoutTransitionState()

    public var isAwaitingLayout: Bool {
        switch phase {
        case .awaitingStartLayout, .awaitingStopLayout:
            return true
        case .idle, .active:
            return false
        }
    }
}

/// One owner for screen-share start/stop layout generations, expected tile identities,
/// and report settlement. Pending remote-screen activation stays outside this state.
public enum ScreenShareLayoutTransitionPolicy {
    public static let stopLayoutReattachReason = "screen-share-stop-layout-reattach"

    /// Begin remote participant reconciliation only when remote share is involved.
    /// Local-only sharing must not start the wait.
    public static func shouldBeginLayoutReconcile(remote: Bool, local: Bool) -> Bool {
        remote
    }

    public static func shouldSettleImmediately(expectedIdentities: Set<String>) -> Bool {
        expectedIdentities.isEmpty
    }

    public static func beginTransition(
        state: ScreenShareLayoutTransitionState,
        isStartingShare: Bool,
        expectedIdentities: Set<String>
    ) -> ScreenShareLayoutTransitionState {
        let generation = state.generation &+ 1
        if shouldSettleImmediately(expectedIdentities: expectedIdentities) {
            return ScreenShareLayoutTransitionState(
                phase: isStartingShare ? .active : .idle,
                generation: generation,
                expectedIdentities: [],
                reportedIdentities: []
            )
        }
        return ScreenShareLayoutTransitionState(
            phase: isStartingShare
                ? .awaitingStartLayout(generation: generation)
                : .awaitingStopLayout(generation: generation),
            generation: generation,
            expectedIdentities: expectedIdentities,
            reportedIdentities: []
        )
    }

    /// Page or roster changes replace the expected set under a new generation.
    public static func replacingExpectedIdentities(
        state: ScreenShareLayoutTransitionState,
        newIdentities: Set<String>
    ) -> ScreenShareLayoutTransitionState {
        let isStartingShare: Bool
        switch state.phase {
        case .awaitingStartLayout, .active:
            isStartingShare = true
        case .awaitingStopLayout:
            isStartingShare = false
        case .idle:
            isStartingShare = !newIdentities.isEmpty
        }
        return beginTransition(
            state: state,
            isStartingShare: isStartingShare,
            expectedIdentities: newIdentities
        )
    }

    /// A one-arg surface report is accepted only when its captured generation and identity
    /// match the current pending transition. Stale generation N cannot settle pending N+1.
    public static func shouldAcceptSurfaceReport(
        capturedGeneration: UInt64,
        identity: String,
        state: ScreenShareLayoutTransitionState
    ) -> Bool {
        guard capturedGeneration == state.generation else { return false }
        switch state.phase {
        case .awaitingStartLayout(let generation), .awaitingStopLayout(let generation):
            guard generation == capturedGeneration else { return false }
        case .idle, .active:
            return false
        }
        return state.expectedIdentities.contains(identity)
    }

    public static func applyingSurfaceReport(
        capturedGeneration: UInt64,
        identity: String,
        state: ScreenShareLayoutTransitionState
    ) -> ScreenShareLayoutTransitionState {
        guard shouldAcceptSurfaceReport(
            capturedGeneration: capturedGeneration,
            identity: identity,
            state: state
        ) else {
            return state
        }
        var next = state
        next.reportedIdentities.insert(identity)
        guard next.expectedIdentities.isSubset(of: next.reportedIdentities) else {
            return next
        }
        switch next.phase {
        case .awaitingStartLayout:
            next.phase = .active
        case .awaitingStopLayout:
            next.phase = .idle
        case .idle, .active:
            break
        }
        next.expectedIdentities.removeAll()
        next.reportedIdentities.removeAll()
        return next
    }

    /// Stop media reconcile runs after post-expand reports settle, not as an immediate reattach.
    public static func stopReconcileReason(afterPostExpandSettlement: Bool) -> String? {
        afterPostExpandSettlement ? stopLayoutReattachReason : nil
    }
}
