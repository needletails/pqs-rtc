import Foundation

@MainActor
public protocol CallActionDelegate: AnyObject, Sendable {
    func endCall()
    func muteAudio()
    func muteVideo()
    func upgradeDowngrade()
    func toggleSpeakerPhone()
    func showPictureInPicture(_ show: Bool)
}

// Provide default no-op implementations for platform-specific actions
public extension CallActionDelegate {
    func toggleSpeakerPhone() {}
    func showPictureInPicture(_ show: Bool) {}
}

protocol PiPEventReceiverDelegate: AnyObject, Sendable {
    func passPause(_ bool: Bool)
}

@MainActor
public protocol VideoCallDelegate: AnyObject, Sendable {
    func passErrorMessage(_ message: String) async
    func videoUpgraded(_ upgraded: Bool) async
    func deliverCallState(_ state: CallStateMachine.State) async
    func endedCall(_ didEnd: Bool) async
#if os(macOS)
    func passSize(_ size: NSSize) async
#endif
}
