//
//  RTCVideoRenderWrapper.swift
//  pqs-rtc
//
//  Created by Cole M on 4/1/24.
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
