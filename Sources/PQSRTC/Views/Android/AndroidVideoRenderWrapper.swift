//
//  AndroidVideoRenderWrapper.swift
//  pqs-rtc
//
//  Created by Cole M on 10/4/25.
//
//  Copyright (c) 2025 NeedleTails Organization.
//
//  This project is licensed under the MIT License.
//
//  See the LICENSE file for more information.
//
//
//  This file is part of the PQSRTC SDK, which provides
//  Frame Encrypted VoIP Capabilities
//


#if SKIP
import Foundation
import org.webrtc.__

/// Lightweight wrapper for an Android `SurfaceViewRenderer`.
///
/// This indirection lets the rest of the SDK reference renderers without directly depending on
/// UI framework details. The wrapper is responsible for holding a stable identifier and releasing
/// the underlying view when no longer needed.
public final class AndroidVideoRenderWrapper: @unchecked Sendable {
    public let id: String

    /// Backing WebRTC view used by Compose or platform UI.
    internal var surfaceView: org.webrtc.SurfaceViewRenderer?

    /// Creates a wrapper with a stable identifier.
    public init(id: String) {
        self.id = id
    }

    /// Returns the underlying `SurfaceViewRenderer` if available.
    public func getSurfaceViewRenderer() -> org.webrtc.SurfaceViewRenderer? {
        return surfaceView
    }

    /// Releases the underlying renderer and clears references.
    public func release() {
        surfaceView?.release()
        surfaceView = nil
    }
}

/// Local renderer alias used by Android UI surfaces.
typealias AndroidLocalVideoRenderer = AndroidVideoRenderWrapper
/// Remote renderer alias used by Android UI surfaces.
typealias AndroidRemoteVideoRenderer = AndroidVideoRenderWrapper
#endif


