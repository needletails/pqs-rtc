import Foundation
import Testing

@Suite("Apple event-driven attach recovery contracts")
struct AppleEventDrivenAttachRecoveryTests {
    private static func readAppleControllerSource(relativePath: String) throws -> String {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let root = testsDir
            .deletingLastPathComponent() // PQSRTCCompiledSwiftTests
            .deletingLastPathComponent() // Tests
        let url = root.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("iOS renderer recovery uses inbound flow stream, not Task.sleep retry loops")
    func iosRendererRecoveryIsEventDriven() throws {
        let source = try Self.readAppleControllerSource(
            relativePath: "Sources/PQSRTC/Views/Apple/Controllers/iOS/VideoCallViewController+UIKit.swift"
        )
        #expect(source.contains("inboundVideoFlowUpdateStream()"))
        #expect(!source.contains("Task.sleep(nanoseconds: 2_000_000_000)"))
        #expect(!source.contains("attempts < 40"))
        let recoveryFns = [
            "startRemoteRendererRecoveryIfNeeded",
            "startRemoteScreenShareRendererRecoveryIfNeeded",
            "startParticipantRendererRecoveryIfNeeded",
        ]
        for name in recoveryFns {
            #expect(source.contains(name), "Missing \(name)")
        }
        #expect(source.contains("startInboundVideoFlowSamplerIfNeeded"))
    }

    @Test("macOS renderer recovery uses inbound flow stream, not Task.sleep retry loops")
    func macOSRendererRecoveryIsEventDriven() throws {
        let source = try Self.readAppleControllerSource(
            relativePath: "Sources/PQSRTC/Views/Apple/Controllers/macOS/VideoCallViewController+AppKit.swift"
        )
        #expect(source.contains("inboundVideoFlowUpdateStream()"))
        #expect(!source.contains("Task.sleep(nanoseconds: 2_000_000_000)"))
        #expect(!source.contains("attempts < 40"))
        #expect(source.contains("Waiting for mapped remote screen track event"))
    }
}
