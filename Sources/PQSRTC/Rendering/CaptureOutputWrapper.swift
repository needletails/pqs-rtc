//
//  CaptureOutputWrapper.swift
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
import AVKit
import WebRTC

final class CaptureOutputWrapper: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    
    struct CaptureOutputPacket: @unchecked Sendable {
        var output: AVCaptureOutput
        var sampleBuffer: CMSampleBuffer
        var connection: AVCaptureConnection
        var rtcVideoRotation: RTCVideoRotation?
    }
    
    private let lock = NSLock()
    var captureOutput: ((CaptureOutputPacket?) -> Void)?
    
    func captureOutput(_
                       output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection
    ) {
        lock.lock()
        defer { lock.unlock() }
        captureOutput?(
            CaptureOutputPacket(
                output: output,
                sampleBuffer: sampleBuffer,
                connection: connection
            )
        )
    }
}
#endif
