import Foundation
import Testing
@testable import PQSRTC

@Suite("Group participant inbound advancing")
struct GroupParticipantInboundAdvancingPolicyTests {
    @Test("another participant's advancing inbound does not count as this source advancing")
    func otherParticipantInboundIsNotThisSource() {
        #expect(!GroupParticipantInboundAdvancingPolicy.isSourceInboundAdvancing(
            connectionInboundIsAdvancing: true,
            mappedRendererCallbackAgeMs: -1
        ))
        #expect(!GroupParticipantInboundAdvancingPolicy.isSourceInboundAdvancing(
            connectionInboundIsAdvancing: false,
            mappedRendererCallbackAgeMs: 12
        ))
        #expect(GroupParticipantInboundAdvancingPolicy.isSourceInboundAdvancing(
            connectionInboundIsAdvancing: true,
            mappedRendererCallbackAgeMs: 0
        ))
        #expect(GroupParticipantInboundAdvancingPolicy.isSourceInboundAdvancing(
            connectionInboundIsAdvancing: true,
            mappedRendererCallbackAgeMs: 40
        ))
    }

    @Test("Apple unanswered mediaReady refresh uses per-tile advancing")
    func unansweredRefreshUsesPerTileAdvancing() throws {
        let ios = try SourceContract.sourceBody(
            of: "startParticipantRendererRecoveryIfNeeded",
            in: try source("Sources/PQSRTC/Views/Apple/Controllers/iOS/VideoCallViewController+UIKit.swift")
        )
        let mac = try SourceContract.sourceBody(
            of: "startParticipantRendererRecoveryIfNeeded",
            in: try source("Sources/PQSRTC/Views/Apple/Controllers/macOS/VideoCallViewController+AppKit.swift")
        )
        #expect(ios.contains("GroupParticipantInboundAdvancingPolicy.isSourceInboundAdvancing"))
        #expect(mac.contains("GroupParticipantInboundAdvancingPolicy.isSourceInboundAdvancing"))
        #expect(ios.contains("mappedRendererCallbackAgeMs: callbackAgeMs"))
        #expect(mac.contains("mappedRendererCallbackAgeMs: callbackAgeMs"))
        #expect(!ios.contains("Task.sleep"))
        #expect(!mac.contains("Task.sleep"))
    }

    private func source(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
