import Foundation
import Testing

@testable import PQSRTC

#if canImport(WebRTC) && !os(Android)
import CoreVideo
import WebRTC

/// The render-safe copy in ``RTCVideoRenderWrapper`` allocates its own destination pixel buffer,
/// whose bytes-per-row CoreVideo picks. A decoded source buffer can carry different row padding,
/// so every row must land at the destination's own row offset.
@Suite(.serialized)
struct RenderFrameCopyRowStrideTests {
    private final class FrameBox: @unchecked Sendable {
        var frame: RTCVideoFrame?
    }

    private struct Plane {
        let width: Int
        let height: Int
        /// Bytes of real pixel data in one row.
        let rowWidthBytes: Int
    }

    private static let width = 90
    private static let height = 6
    private static let padByte: UInt8 = 0xEE

    private static func pattern(plane: Int, row: Int, column: Int) -> UInt8 {
        UInt8(truncatingIfNeeded: plane &* 97 &+ row &* 31 &+ column)
    }

    private static func planes(for format: OSType) -> [Plane] {
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            return [
                Plane(width: width, height: height, rowWidthBytes: width),
                Plane(width: width / 2, height: height / 2, rowWidthBytes: width)
            ]
        default:
            return [Plane(width: width, height: height, rowWidthBytes: width * 4)]
        }
    }

    /// Source rows filled with a row-dependent pattern and padded to `stride` bytes.
    private static func fill(_ base: UnsafeMutableRawPointer, plane: Int, info: Plane, stride: Int) {
        for row in 0..<info.height {
            let rowStart = base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self)
            for column in 0..<stride {
                rowStart[column] = column < info.rowWidthBytes ? pattern(plane: plane, row: row, column: column) : padByte
            }
        }
    }

    /// Copies a source buffer whose rows are `sourceStride` bytes through the renderer and returns
    /// the first mismatching destination row, or nil when every row arrived intact.
    private func firstCorruptRow(format: OSType, sourceStride: Int) throws -> String? {
        let planes = Self.planes(for: format)
        let storage = planes.map { UnsafeMutableRawPointer.allocate(byteCount: sourceStride * $0.height, alignment: 64) }
        defer { storage.forEach { $0.deallocate() } }
        for (index, plane) in planes.enumerated() {
            Self.fill(storage[index], plane: index, info: plane, stride: sourceStride)
        }

        var source: CVPixelBuffer?
        let status: CVReturn
        if planes.count > 1 {
            var baseAddresses: [UnsafeMutableRawPointer?] = storage
            var widths = planes.map(\.width)
            var heights = planes.map(\.height)
            var strides = planes.map { _ in sourceStride }
            status = CVPixelBufferCreateWithPlanarBytes(
                kCFAllocatorDefault, Self.width, Self.height, format,
                nil, 0, planes.count,
                &baseAddresses, &widths, &heights, &strides,
                nil, nil, nil, &source
            )
        } else {
            status = CVPixelBufferCreateWithBytes(
                kCFAllocatorDefault, Self.width, Self.height, format,
                storage[0], sourceStride, nil, nil, nil, &source
            )
        }
        try #require(status == kCVReturnSuccess)
        let sourceBuffer = try #require(source)

        let renderer = RTCVideoRenderWrapper(id: "row-stride")
        let box = FrameBox()
        renderer.frameOutput = { box.frame = $0 }
        renderer.renderFrame(RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: sourceBuffer), rotation: ._0, timeStampNs: 1))

        let copied = try #require((box.frame?.buffer as? RTCCVPixelBuffer)?.pixelBuffer)
        try #require(copied !== sourceBuffer)
        CVPixelBufferLockBaseAddress(copied, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(copied, .readOnly) }

        for (index, plane) in planes.enumerated() {
            let base = planes.count > 1 ? CVPixelBufferGetBaseAddressOfPlane(copied, index) : CVPixelBufferGetBaseAddress(copied)
            let destinationStride = planes.count > 1 ? CVPixelBufferGetBytesPerRowOfPlane(copied, index) : CVPixelBufferGetBytesPerRow(copied)
            // Otherwise the case does not exercise a stride mismatch.
            try #require(destinationStride != sourceStride)
            let destination = try #require(base).assumingMemoryBound(to: UInt8.self)
            for row in 0..<plane.height {
                for column in 0..<plane.rowWidthBytes
                where destination[row * destinationStride + column] != Self.pattern(plane: index, row: row, column: column) {
                    return "plane \(index) row \(row) column \(column) (source stride \(sourceStride), destination stride \(destinationStride))"
                }
            }
        }
        return nil
    }

    @Test("NV12 rows with tighter source padding keep their row alignment in the copy")
    func nv12NarrowerSourceRowsKeepAlignment() throws {
        let corruptRow = try firstCorruptRow(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, sourceStride: Self.width)
        #expect(corruptRow == nil)
    }

    @Test("NV12 rows with wider source padding are not copied past the destination row")
    func nv12WiderSourceRowsKeepAlignment() throws {
        let corruptRow = try firstCorruptRow(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, sourceStride: 1024)
        #expect(corruptRow == nil)
    }

    @Test("BGRA rows with tighter source padding keep their row alignment in the copy")
    func bgraNarrowerSourceRowsKeepAlignment() throws {
        let corruptRow = try firstCorruptRow(format: kCVPixelFormatType_32BGRA, sourceStride: Self.width * 4)
        #expect(corruptRow == nil)
    }

    @Test("BGRA rows with wider source padding are not copied past the destination row")
    func bgraWiderSourceRowsKeepAlignment() throws {
        let corruptRow = try firstCorruptRow(format: kCVPixelFormatType_32BGRA, sourceStride: 2048)
        #expect(corruptRow == nil)
    }
}
#endif
