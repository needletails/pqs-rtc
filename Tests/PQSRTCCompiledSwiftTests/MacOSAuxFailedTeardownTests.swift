import Foundation
import Testing

@testable import PQSRTC

@Suite(.serialized)
struct MacOSAuxFailedTeardownTests {
    @Test("aux-device and failed states retain the Call through teardown")
    func auxDeviceAndFailedRetainCallThroughTeardown() throws {
        let source = try self.source(
            "Sources/PQSRTC/Views/Apple/Controllers/macOS/VideoCallViewController+AppKit.swift"
        )
        #expect(source.contains("case .failed(_, let failedCall, let errorMessage):"))
        #expect(source.contains("case .callAnsweredAuxDevice(let answeredCall):"))
        #expect(source.contains("if currentCall == nil {\n                        currentCall = failedCall"))
        #expect(source.contains("if currentCall == nil {\n                        currentCall = answeredCall"))
        #expect(!source.contains("currentCall = nil\n                    await tearDownCall()"))
    }

    private func source(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
