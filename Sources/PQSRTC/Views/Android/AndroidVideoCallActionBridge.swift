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
    private var controller: AndroidVideoCallController?

    public init() {}

    public func bind(_ controller: AndroidVideoCallController) {
        self.controller = controller
    }

    public func clearBinding() {
        controller = nil
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
