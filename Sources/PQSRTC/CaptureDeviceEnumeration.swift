//
//  CaptureDeviceEnumeration.swift
//  pqs-rtc
//

#if os(iOS) || os(macOS)
import AVFoundation

extension PQSRTCCallUIPreferences {
    /// Video capture devices suitable for local preview / WebRTC injection.
    public static func availableVideoCaptureDevices() -> [AVCaptureDevice] {
        let types: [AVCaptureDevice.DeviceType]
#if os(iOS)
        types = [
            .builtInWideAngleCamera,
            .builtInDualCamera,
            .builtInDualWideCamera,
            .builtInTripleCamera,
            .builtInTrueDepthCamera,
        ]
#else
        types = [.builtInWideAngleCamera, .externalUnknown]
#endif
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .unspecified
        )
        return session.devices
    }
}
#endif
