//
//  MTKViewDelegateWrapper.swift
//  needle-tail-rtc
//
//  Created by Cole M on 1/11/25.
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
#if os(iOS) || os(macOS)
import MetalKit

@MainActor
final class MTKViewDelegateWrapper: NSObject, MTKViewDelegate {

    private let lock = NSLock()
    var capturedView: ((MTKView?) -> Void)?

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    
    func draw(in view: MTKView) {
        lock.lock()
        defer { lock.unlock() }
        capturedView?(view)
    }
    deinit {
        // Intentionally no print; rely on logger if needed
    }
}
#endif
