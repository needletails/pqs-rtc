#if canImport(CoreImage) && (os(iOS) || os(macOS))
import CoreImage
#if canImport(WebRTC)
import WebRTC
#endif

/// Host-side JPEG decode and display orientation for ReplayKit screen-share frames.
enum ReplayKitScreenShareJPEGOrientation {
    static func needsHostUprightCorrection(width: Int, height: Int) -> Bool {
        false
    }

    static func cgImageOrientation(forRawValue rawValue: UInt8) -> CGImagePropertyOrientation {
        CGImagePropertyOrientation(rawValue: UInt32(rawValue)) ?? .up
    }

    static func displayOrientation(forReplayKitRawValue rawValue: UInt8) -> CGImagePropertyOrientation {
        switch cgImageOrientation(forRawValue: rawValue) {
        case .right:
            return .left
        case .rightMirrored:
            return .leftMirrored
        case .left:
            return .right
        case .leftMirrored:
            return .rightMirrored
        default:
            return cgImageOrientation(forRawValue: rawValue)
        }
    }

    static func uprightCIImage(_ image: CIImage, orientationRawValue: UInt8) -> CIImage {
        let orientation = displayOrientation(forReplayKitRawValue: orientationRawValue)
        guard orientation != .up else { return image }
        return image.oriented(orientation)
    }

#if canImport(WebRTC)
    static func cgImageOrientation(forWebRTCRotation rotation: RTCVideoRotation) -> CGImagePropertyOrientation? {
        switch rotation {
        case ._0:
            return nil
        case ._90:
            return .right
        case ._180:
            return .down
        case ._270:
            return .left
        @unknown default:
            return nil
        }
    }

    static func uprightCIImage(_ image: CIImage, webRTCRotation: RTCVideoRotation) -> CIImage {
        guard let orientation = cgImageOrientation(forWebRTCRotation: webRTCRotation) else { return image }
        return image.oriented(orientation)
    }

    static func videoRotation(forRawValue rawValue: UInt8) -> RTCVideoRotation {
        let orientation = displayOrientation(forReplayKitRawValue: rawValue)
        switch orientation {
        case .up, .upMirrored:
            return ._0
        case .right, .rightMirrored:
            return ._90
        case .down, .downMirrored:
            return ._180
        case .left, .leftMirrored:
            return ._270
        default:
            return ._0
        }
    }
#endif

    static func normalizedUprightImage(_ image: CIImage) -> (image: CIImage, width: Int, height: Int) {
        let extent = image.extent.integral
        let translated = image.transformed(
            by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
        )
        return (
            translated,
            max(2, Int(extent.width.rounded())),
            max(2, Int(extent.height.rounded()))
        )
    }

#if canImport(WebRTC)
    static func uprightPixelBuffer(
        from pixelBuffer: CVPixelBuffer,
        webRTCRotation rotation: RTCVideoRotation,
        context: CIContext
    ) -> CVPixelBuffer? {
        guard rotation != ._0 else { return pixelBuffer }

        let uprightImage = uprightCIImage(CIImage(cvPixelBuffer: pixelBuffer), webRTCRotation: rotation)
        let (normalizedImage, outputWidth, outputHeight) = normalizedUprightImage(uprightImage)

        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]

        var outputBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            outputWidth,
            outputHeight,
            CVPixelBufferGetPixelFormatType(pixelBuffer),
            attributes as CFDictionary,
            &outputBuffer
        )
        guard status == kCVReturnSuccess, let outputBuffer else { return nil }

        context.render(
            normalizedImage,
            to: outputBuffer,
            bounds: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return outputBuffer
    }
#endif
}
#endif
