//
//  AndroidVideoRenderWrapper.swift
//  needle-tail-rtc
//
//  Created by Cole M on 10/4/25.
//


#if SKIP
import Foundation
import org.webrtc.__

/// Common wrapper used by AndroidVideoView to interact with a renderer
public final class AndroidVideoRenderWrapper: @unchecked Sendable {
    public let id: String

    /// Backing WebRTC view used by Compose or platform UI
    internal var surfaceView: org.webrtc.SurfaceViewRenderer?

    public init(id: String) {
        self.id = id
    }

    /// Returns the underlying SurfaceViewRenderer if available
    public func getSurfaceViewRenderer() -> org.webrtc.SurfaceViewRenderer? {
        return surfaceView
    }

    /// Release any underlying resources
    public func release() {
        surfaceView?.release()
        surfaceView = nil
    }
}

typealias AndroidLocalVideoRenderer = AndroidVideoRenderWrapper
typealias AndroidRemoteVideoRenderer = AndroidVideoRenderWrapper
#endif


