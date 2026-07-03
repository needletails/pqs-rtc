//
//  RemoteVideoRenderOverlayPolicy.swift
//  pqs-rtc
//
//  Signal-like remote tile UX: hold the last decoded frame during brief gaps and
//  only show the pause overlay when inbound video has genuinely stopped flowing.
//

import Foundation

/// High-level inbound remote video flow classification used by tile overlay and recovery logic.
enum InboundVideoFlowState: String, Sendable {
    case noTraffic
    case stalledIngress
    case advancingIngress
    case decodeStalled
}

/// Decides when to show the render-frozen (pause) tile overlay on remote video.
///
/// The app-level network quality banner covers "bad link" UX; this overlay is reserved
/// for prolonged stalls where no new inbound video is arriving.
enum RemoteVideoRenderOverlayPolicy {
    /// Show pause chrome only after inbound video has been flat this long (ms).
    static let showAfterStalledIngressMs: Int64 = 12_000

    /// Hide pause chrome once renderer callbacks resume (ms).
    static let hideAfterFrameResumeMs: Int64 = 1_500

    /// While packets or decodes are still advancing, hold the last frame without pause chrome.
    static func shouldShowRenderFrozenOverlay(
        frameCallbackAgeMs: Int64,
        inboundFlowState: InboundVideoFlowState?,
        showsFrozen: inout Bool
    ) -> Bool {
        guard frameCallbackAgeMs >= 0 else {
            showsFrozen = false
            return false
        }
        if frameCallbackAgeMs <= hideAfterFrameResumeMs {
            showsFrozen = false
            return false
        }

        if let inboundFlowState {
            switch inboundFlowState {
            case .advancingIngress, .decodeStalled:
                // Media is still arriving (or decode is catching up) - keep last frame visible.
                showsFrozen = false
                return false
            case .noTraffic, .stalledIngress:
                break
            }
        }

        if frameCallbackAgeMs >= showAfterStalledIngressMs {
            showsFrozen = true
            return true
        }
        return showsFrozen
    }
}
