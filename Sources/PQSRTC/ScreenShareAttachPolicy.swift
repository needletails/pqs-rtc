import Foundation

public enum ScreenShareDuplicateActivationDecision: Equatable, Sendable {
    case ignore
    case refreshExisting
    case recreate
}

/// Pure attach/skip decisions for remote screen-share renderers.
public enum ScreenShareAttachPolicy {
    /// Same-presenter `isActive` is an idempotent refresh, not ignore or recreate.
    public static func duplicateActivationDecision(
        isActive: Bool,
        samePresenterAlreadyActive: Bool
    ) -> ScreenShareDuplicateActivationDecision {
        guard isActive, samePresenterAlreadyActive else { return .recreate }
        return .refreshExisting
    }

    /// Skip only when the renderer already has a healthy sink on the currently mapped wrapper
    /// and layout does not need reconcile. A live sink on a different wrapper is a rebind.
    public static func shouldSkipScreenRendererAttach(
        hasActiveSink: Bool,
        attachedTrackIsLive: Bool,
        sharesMappedWrapper: Bool,
        layoutNeedsReconcile: Bool
    ) -> Bool {
        hasActiveSink
            && attachedTrackIsLive
            && sharesMappedWrapper
            && !layoutNeedsReconcile
    }

    /// Wrapper A → wrapper B with the same negotiated `trackId` is still a rebind.
    public static func shouldRebindScreenWrapper(
        storedTrackId: String?,
        liveTrackId: String?,
        platformTracksIdentical: Bool
    ) -> Bool {
        if !platformTracksIdentical {
            return true
        }
        guard let storedTrackId, let liveTrackId,
              !storedTrackId.isEmpty, !liveTrackId.isEmpty else {
            return !platformTracksIdentical
        }
        return storedTrackId != liveTrackId
    }
}
