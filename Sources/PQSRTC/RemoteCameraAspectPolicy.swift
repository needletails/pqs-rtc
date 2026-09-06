//
//  RemoteCameraAspectPolicy.swift
//  pqs-rtc
//
//  Solo remote and share-strip camera items fill when the remote upright frame
//  matches the item. Conference grids letterbox. Mismatched pairs aspect-fit.
//

import Foundation

/// Decides aspect-fit vs aspect-fill for remote camera presentation on mobile.
public enum RemoteCameraAspectPolicy: Sendable {

    /// - Parameters:
    ///   - forceFit: Multi-remote conference grids always letterbox.
    ///   - fillWhenOrientationMatches: Fill only when the remote upright orientation matches the item.
    ///   - remoteWidth/remoteHeight: Upright remote frame size (rotation already applied).
    ///   - localWidth/localHeight: Host viewport / item bounds.
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

    /// Conference grids keep uniform 16:9 tiles and letterbox every sender.
    /// A screen-share strip sizes each remote **item** to the incoming upright frame, then
    /// match-fills so landscape content can go end-to-end of that item.
    public static func forceFitForCameraTiles(
        cameraTileCount: Int,
        hasVisibleScreenShare: Bool
    ) -> Bool {
        cameraTileCount > 1 && !hasVisibleScreenShare
    }

    /// Solo fullscreen and screen-share strip cameras fill only when the remote upright
    /// orientation matches the **item** (not the leftover collection band).
    public static func fillWhenOrientationMatchesForCameraTiles(
        cameraTileCount: Int,
        hasVisibleScreenShare: Bool
    ) -> Bool {
        cameraTileCount == 1 || hasVisibleScreenShare
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

    /// Same as ``prefersAspectFit(forceFit:fillWhenOrientationMatches:remoteWidth:remoteHeight:localWidth:localHeight:)``
    /// after applying WebRTC rotation to the source buffer size.
    public static func prefersAspectFit(
        forceFit: Bool,
        fillWhenOrientationMatches: Bool,
        sourceWidth: Double,
        sourceHeight: Double,
        rotationDegrees: Int,
        destinationWidth: Double,
        destinationHeight: Double
    ) -> Bool {
        let upright = uprightDimensions(
            width: Int(sourceWidth.rounded()),
            height: Int(sourceHeight.rounded()),
            rotationDegrees: rotationDegrees
        )
        return prefersAspectFit(
            forceFit: forceFit,
            fillWhenOrientationMatches: fillWhenOrientationMatches,
            remoteWidth: Double(upright.width),
            remoteHeight: Double(upright.height),
            localWidth: destinationWidth,
            localHeight: destinationHeight
        )
    }

    /// Centers `source` inside `destination` without cropping or stretching.
    ///
    /// Used both for Metal rasterization into a collection cell and for the final
    /// drawable blit so a stale portrait texture cannot be stretched into a
    /// landscape strip cell.
    public static func letterboxedRect(
        sourceWidth: Double,
        sourceHeight: Double,
        destinationWidth: Double,
        destinationHeight: Double
    ) -> (x: Double, y: Double, width: Double, height: Double) {
        guard sourceWidth > 0, sourceHeight > 0, destinationWidth > 0, destinationHeight > 0 else {
            return (0, 0, max(0, destinationWidth), max(0, destinationHeight))
        }
        let scale = min(destinationWidth / sourceWidth, destinationHeight / sourceHeight)
        let width = sourceWidth * scale
        let height = sourceHeight * scale
        return (
            (destinationWidth - width) / 2,
            (destinationHeight - height) / 2,
            width,
            height
        )
    }
}
