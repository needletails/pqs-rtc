//
//  MTKViewDelegateWrapper.swift
//  pqs-rtc
//
//  Created by Cole M on 1/11/25.
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
