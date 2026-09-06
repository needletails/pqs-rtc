import Foundation
import Testing

@testable import PQSRTC

@Suite(.serialized)
struct AppleTeardownRecoveryTests {
    @Test("tearDownCall cancels recovery tasks first")
    func tearDownCallCancelsRecoveryTasksFirst() throws {
        let relativePaths = [
            "Sources/PQSRTC/Views/Apple/Controllers/iOS/VideoCallViewController+UIKit.swift",
            "Sources/PQSRTC/Views/Apple/Controllers/macOS/VideoCallViewController+AppKit.swift",
        ]
        for relativePath in relativePaths {
            let source = try self.source(relativePath)
            let body = try SourceContract.sourceBody(of: "tearDownCall", in: source)
            let stopRemote = body.range(of: "stopRemoteRendererRecovery()")
            let stopParticipants = body.range(of: "stopAllParticipantRendererRecovery()")
            let stopScreen = body.range(of: "stopAllScreenShareRendererRecovery()")
            let isRunningFalse = body.range(of: "isRunning = false")
            #expect(stopRemote != nil, "\(relativePath) must cancel remote recovery first")
            #expect(stopParticipants != nil)
            #expect(stopScreen != nil)
            #expect(isRunningFalse != nil)
            if let stopRemote, let isRunningFalse {
                #expect(stopRemote.lowerBound < isRunningFalse.lowerBound)
            }
        }
    }

    private func source(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
