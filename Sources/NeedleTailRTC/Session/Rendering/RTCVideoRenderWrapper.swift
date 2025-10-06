//
//  RTCVideoRenderWrapper.swift
//  needle-tail-rtc
//
//  Created by Cole M on 4/1/24.
//
//  Copyright (c) 2025 NeedleTails Organization.
//
//  This project is proprietary and confidential.
//
//  All rights reserved. Unauthorized copying, distribution, or use
//  of this software is strictly prohibited.
//
//  This file is part of the NeedleTailRTC SDK, which provides
//  VoIP Capabilities
//

#if !os(Android)
@preconcurrency import WebRTC

final class RTCVideoRenderWrapper: NSObject, RTCVideoRenderer, @unchecked Sendable {
    
    let id: String
    let needsRendering: Bool
    private let lock = NSLock()
    var frameOutput: (@Sendable (RTCVideoFrame?) -> Void)?
    
    init(id: String, needsRendering: Bool = true) {
        self.id = id
        self.needsRendering = needsRendering
    }
    
     func renderFrame(_ frame: RTCVideoFrame?) {
         if needsRendering {
             lock.lock()
             defer { lock.unlock() }
             frameOutput?(frame)
         }
    }
    
    func setSize(_ size: CGSize) {}
}
#endif
