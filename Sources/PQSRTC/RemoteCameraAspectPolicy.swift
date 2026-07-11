//
//  RemoteCameraAspectPolicy.swift
//  pqs-rtc
//
//  Solo remote camera tiles fill only when the remote upright frame orientation matches
//  the local viewport. Mismatched portrait/landscape pairs letterbox (aspect-fit).
//

import Foundation

/// Decides aspect-fit vs aspect-fill for remote camera presentation on mobile.
public enum RemoteCameraAspectPolicy: Sendable {

    /// - Parameters:
    ///   - forceFit: Multi-remote grids and screen-share strips always letterbox.
    ///   - fillWhenOrientationMatches: Solo fullscreen path: fill only when orientations agree.
    ///   - remoteWidth/remoteHeight: Upright remote frame size (rotation already applied).
    ///   - localWidth/localHeight: Host viewport size (device / tile bounds).
    /// - Returns: `true` when the renderer should aspect-fit (letterbox) instead of fill.
    public static func prefersAspectFit(
        forceFit: Bool,
        fillWhenOrientationMatches: Bool,
        remoteWidth: Double,
        remoteHeight: Double,
        localWidth: Double,
        localHeight: Double
    ) -> Bool {
        if forceFit { return true }
        guard fillWhenOrientationMatches else { return false }
        guard remoteWidth > 0, remoteHeight > 0, localWidth > 0, localHeight > 0 else {
            // Unknown remote orientation: letterbox so we never crop a mismatched sender.
            return true
        }
        let remoteLandscape = remoteWidth > remoteHeight
        let localLandscape = localWidth > localHeight
        return remoteLandscape != localLandscape
    }

    /// WebRTC `rotation` is clockwise degrees; 90/270 swap the upright width/height.
    public static func uprightDimensions(
        width: Int,
        height: Int,
        rotationDegrees: Int
    ) -> (width: Int, height: Int) {
        let rot = ((rotationDegrees % 360) + 360) % 360
        if rot == 90 || rot == 270 {
            return (height, width)
        }
        return (width, height)
    }
}
