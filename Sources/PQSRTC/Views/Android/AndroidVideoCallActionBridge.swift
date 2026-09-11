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
///
/// Not `@MainActor`: chrome taps must hop off the Android UI thread before awaiting the
/// session actor. Skip can pin the main looper across `await` when this type is main-isolated,
/// which ANRs if `RTCSession` is busy in `setLocalDescription`.
public final class AndroidVideoCallActionBridge: CallActionDelegate, @unchecked Sendable {
    private static let logger = NeedleTailLogger(level: .info)
    private static let active = ActiveBridgeStorage()
    fileprivate var controller: AndroidVideoCallController?

    public init() {}

    public func bind(_ controller: AndroidVideoCallController) {
        Self.active.bind(self, controller: controller)
    }

    public func clearBinding() {
        Self.active.clear(self)
    }

    private func lockedController() -> AndroidVideoCallController? {
        Self.active.controller(for: self)
    }

    private static func lockedActiveController() -> AndroidVideoCallController? {
        active.controller()
    }

    /// Hides or restores native video surfaces for the active in-call bridge (minimize/browse).
    public static func setActiveCallVideoSurfacesHidden(_ hidden: Bool) async {
        await lockedActiveController()?.setVideoSurfacesHidden(hidden)
    }

    /// Updates renderer visibility policy on the controller actor before Android enters or exits PiP.
    public static func setKeepRemoteSurfacesVisibleForSystemPiP(_ keepVisible: Bool) async {
        await lockedActiveController()?.setKeepRemoteSurfacesVisibleForSystemPiP(keepVisible)
    }

    public static func setKeepLocalPreviewHiddenForPictureInPicture(_ hidden: Bool) async {
        await lockedActiveController()?.setKeepLocalPreviewHiddenForPictureInPicture(hidden)
    }

    /// Rebinds live tracks after Android recreates SurfaceViews on app foreground.
    public static func reconcileActiveCallVideoSurfacesAfterForeground() async {
        await lockedActiveController()?.reconcileVideoSurfacesAfterAppForeground()
    }

    public func setVideoSurfacesHidden(_ hidden: Bool) async {
        await lockedController()?.setVideoSurfacesHidden(hidden)
    }

    public func reconcileVideoSurfacesAfterAppForeground() async {
        await lockedController()?.reconcileVideoSurfacesAfterAppForeground()
    }

    public static func hasVisibleScreenShareForPiP() async -> Bool {
        await lockedActiveController()?.hasVisibleScreenShareForPiP() ?? false
    }

    public func endCall() async {
        await lockedController()?.endCall()
    }

    public func muteAudio() async {
        await lockedController()?.muteAudio()
    }

    public func setAudioMuted(_ muted: Bool) async {
        guard let controller = lockedController() else {
            Self.logger.log(
                level: .warning,
                message: "AndroidVideoCallActionBridge.setAudioMuted(\(muted)) ignored; controller not bound"
            )
            return
        }
        await controller.setAudioMuted(muted)
    }

    public func muteVideo() async {
        await lockedController()?.muteVideo()
    }

    public func setVideoMuted(_ muted: Bool) async {
        guard let controller = lockedController() else {
            Self.logger.log(
                level: .warning,
                message: "AndroidVideoCallActionBridge.setVideoMuted(\(muted)) ignored; controller not bound"
            )
            return
        }
        await controller.setVideoMuted(muted)
    }

    public func startScreenShare(target: ScreenShareTarget) async {
        await lockedController()?.startScreenShare(target: target)
    }

    public func startScreenShare(target: ScreenShareTarget, options: ScreenShareOptions) async {
        await lockedController()?.startScreenShare(target: target, options: options)
    }

    public func startScreenShareAndReport(target: ScreenShareTarget, options: ScreenShareOptions) async -> Bool {
        await lockedController()?.startScreenShareAndReport(target: target, options: options) ?? false
    }

    public func stopScreenShare() async {
        await lockedController()?.stopScreenShare()
    }
}

/// Lock-protected weak active-bridge pointer. A `let` box keeps the static concurrency-safe.
private final class ActiveBridgeStorage: @unchecked Sendable {
    private let lock = NSLock()
    private weak var bridge: AndroidVideoCallActionBridge?

    func bind(_ bridge: AndroidVideoCallActionBridge, controller: AndroidVideoCallController) {
        lock.lock()
        bridge.controller = controller
        self.bridge = bridge
        lock.unlock()
    }

    func clear(_ bridge: AndroidVideoCallActionBridge) {
        lock.lock()
        bridge.controller = nil
        if self.bridge === bridge {
            self.bridge = nil
        }
        lock.unlock()
    }

    func controller(for bridge: AndroidVideoCallActionBridge) -> AndroidVideoCallController? {
        lock.lock()
        defer { lock.unlock() }
        return bridge.controller
    }

    func controller() -> AndroidVideoCallController? {
        lock.lock()
        defer { lock.unlock() }
        return bridge?.controller
    }
}
#endif
