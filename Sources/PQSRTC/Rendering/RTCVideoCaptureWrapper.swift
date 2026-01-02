//
//  RTCVideoCaptureWrapper.swift
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
import WebRTC
import NeedleTailLogger
final class RTCVideoCaptureWrapper: RTCVideoCapturer, @unchecked Sendable {
    
    private let lock = NSLock()
    private var nanoseconds: Float64 = 0
    private let kNanosecondsPerSecond: Float64 = 1000000000
    
    override internal init(delegate: RTCVideoCapturerDelegate) {
        super.init(delegate: delegate)
    }
    
    func passCapture(
        pixelBuffer: CVPixelBuffer,
        captureSession: AVCaptureSession,
        sampleBuffer: CMSampleBuffer,
        connection: AVCaptureConnection,
        rotation: RTCVideoRotation
    ) {
        lock.lock()
        defer {
            lock.unlock()
        }
        let timeStampNs = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * kNanosecondsPerSecond
        let rtcPixelBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let rtcVideoFrame = RTCVideoFrame(buffer: rtcPixelBuffer, rotation: rotation, timeStampNs: Int64(timeStampNs))
        self.delegate?.capturer(self, didCapture: rtcVideoFrame)
    }
}
#endif
