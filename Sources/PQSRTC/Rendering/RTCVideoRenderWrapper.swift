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
import NeedleTailLogger

final class RTCVideoRenderWrapper: NSObject, RTCVideoRenderer, @unchecked Sendable {
    
    let id: String
    let needsRendering: Bool
    private let lock = NSLock()
    var frameOutput: (@Sendable (RTCVideoFrame?) -> Void)?
    private let logger: NeedleTailLogger
    
    init(id: String, needsRendering: Bool = true) {
        self.id = id
        self.needsRendering = needsRendering
        self.logger = NeedleTailLogger("[RTCVideoRenderWrapper:\(id)]")
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
        if needsRendering {
            lock.lock()
            defer { lock.unlock() }
            frameOutput?(makeRenderSafeFrameCopy(frame))
        }
    }
    
    func setSize(_ size: CGSize) {}

    /// Produces a frame whose pixel planes remain valid after this method returns.
    ///
    /// **Why this exists:** WebRTC’s decoder often **reuses the same backing memory** for successive
    /// decoded frames. `RTCVideoRenderer.renderFrame` is synchronous; as soon as it returns, the
    /// implementation is free to overwrite those bytes for the next frame. Our pipeline **captures**
    /// the `RTCVideoFrame` and processes it on **actors / async tasks** (Metal, sample-buffer enqueue,
    /// etc.), so without a copy we were sometimes sampling **stale or partially updated** planes.
    ///
    /// That showed up as severe image corruption on the receive path (e.g. **green tint**, blocky
    /// **macroblocking**, wrong colors) because chroma/luma no longer matched a coherent frame.
    ///
    /// **Mitigation:** normalize to I420 and **`memcpy` each plane** into an `RTCMutableI420Buffer` on
    /// the WebRTC callback thread *before* yielding to async consumers.
    private func makeRenderSafeFrameCopy(_ frame: RTCVideoFrame?) -> RTCVideoFrame? {
        guard let frame else { return nil }
        let i420Buffer = frame.buffer.toI420()

        let copiedBuffer = RTCMutableI420Buffer(
            width: i420Buffer.width,
            height: i420Buffer.height,
            strideY: i420Buffer.strideY,
            strideU: i420Buffer.strideU,
            strideV: i420Buffer.strideV
        )

        let yHeight = Int(i420Buffer.height)
        let chromaHeight = Int(i420Buffer.chromaHeight)
        let yBytes = Int(i420Buffer.strideY) * yHeight
        let uBytes = Int(i420Buffer.strideU) * chromaHeight
        let vBytes = Int(i420Buffer.strideV) * chromaHeight

        memcpy(copiedBuffer.mutableDataY, i420Buffer.dataY, yBytes)
        memcpy(copiedBuffer.mutableDataU, i420Buffer.dataU, uBytes)
        memcpy(copiedBuffer.mutableDataV, i420Buffer.dataV, vBytes)

        return RTCVideoFrame(
            buffer: copiedBuffer,
            rotation: frame.rotation,
            timeStampNs: frame.timeStampNs
        )
    }
}
#endif
