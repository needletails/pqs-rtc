import Foundation
import Testing

/// `PreviewViewRender` cannot be built in this harness: its init asks for camera access
/// (`AVCaptureDevice.requestAccess`) and opens the real camera. So this is a source contract.
@Suite("Preview capture loop survives a failed frame")
struct PreviewCaptureLoopFrameErrorTests {
    private static func previewViewRenderSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // PQSRTCCompiledSwiftTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("Sources/PQSRTC/Rendering/PreviewViewRender.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The same loop injects every camera frame into WebRTC, so a Metal preview error on one frame
    /// (createMetalImage throws) must not end it. A non-throwing `startStream` makes the compiler
    /// enforce that; no do/catch before the loop means the catch is per frame, not around the loop.
    @Test("A per-frame error does not end the preview capture loop")
    func previewCaptureLoopCatchesPerFrameErrors() throws {
        let body = try SourceContract.sourceBody(of: "startStream(ciContext", in: try Self.previewViewRenderSource())
        let header = try #require(body.firstIndex(of: "{").map { body[..<$0] })
        #expect(!header.contains("throws"), "startStream must not propagate a per-frame error: \(header)")

        let loop = try #require(body.range(of: "for await packet in stream"))
        #expect(!body[..<loop.lowerBound].contains("do {"), "a catch around the whole loop still ends it on the first error")
        #expect(body[loop.upperBound...].contains("self.handleOutputStream(packet"))
    }
}
