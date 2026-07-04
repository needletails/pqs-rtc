//
//  AndroidVideoCallActionBridge.swift
//  pqs-rtc
//
//  Copyright (c) 2025 NeedleTails Organization.
//

#if os(Android)
import Foundation
import NeedleTailLogger

/// Forwards mute/end actions to the hosted ``AndroidVideoCallController``.
///
/// Host apps should keep one instance in `@State` and pass it into ``AndroidVideoCallView``
/// instead of relying on `Binding<CallActionDelegate?>` to hold the controller: assigning the
/// controller into that binding is not reliably persisted across SwiftUI updates in Skip stacks,
/// which leaves overlay controls with a `nil` delegate.
@MainActor
public final class AndroidVideoCallActionBridge: CallActionDelegate, @unchecked Sendable {
    private static let logger = NeedleTailLogger()
    private static weak var activeBridge: AndroidVideoCallActionBridge?
    private var controller: AndroidVideoCallController?

    public init() {}

    public func bind(_ controller: AndroidVideoCallController) {
        self.controller = controller
        Self.activeBridge = self
    }

    public func clearBinding() {
        controller = nil
        if Self.activeBridge === self {
            Self.activeBridge = nil
        }
    }

    /// Hides or restores native video surfaces for the active in-call bridge (minimize/browse).
    public static func setActiveCallVideoSurfacesHidden(_ hidden: Bool) async {
        await activeBridge?.setVideoSurfacesHidden(hidden)
    }

    /// Rebinds live tracks after Android recreates SurfaceViews on app foreground.
    public static func reconcileActiveCallVideoSurfacesAfterForeground() async {
        await activeBridge?.reconcileVideoSurfacesAfterAppForeground()
    }

    public func setVideoSurfacesHidden(_ hidden: Bool) async {
        await controller?.setVideoSurfacesHidden(hidden)
    }

    public func reconcileVideoSurfacesAfterAppForeground() async {
        await controller?.reconcileVideoSurfacesAfterAppForeground()
    }

    public func endCall() async {
        await controller?.endCall()
    }

    public func muteAudio() async {
        await controller?.muteAudio()
    }

    public func setAudioMuted(_ muted: Bool) async {
        guard let controller else {
            Self.logger.log(
                level: .warning,
                message: "AndroidVideoCallActionBridge.setAudioMuted(\(muted)) ignored; controller not bound"
            )
            return
        }
        await controller.setAudioMuted(muted)
    }

    public func muteVideo() async {
        await controller?.muteVideo()
    }

    public func setVideoMuted(_ muted: Bool) async {
        guard let controller else {
            Self.logger.log(
                level: .warning,
                message: "AndroidVideoCallActionBridge.setVideoMuted(\(muted)) ignored; controller not bound"
            )
            return
        }
        await controller.setVideoMuted(muted)
    }

    public func startScreenShare(target: ScreenShareTarget) async {
        await controller?.startScreenShare(target: target)
    }

    public func startScreenShare(target: ScreenShareTarget, options: ScreenShareOptions) async {
        await controller?.startScreenShare(target: target, options: options)
    }

    public func startScreenShareAndReport(target: ScreenShareTarget, options: ScreenShareOptions) async -> Bool {
        await controller?.startScreenShareAndReport(target: target, options: options) ?? false
    }

    public func stopScreenShare() async {
        await controller?.stopScreenShare()
    }
}
#endif
