import Foundation
import Testing

@testable import PQSRTC

@Suite(.serialized)
struct StaleSdpAnswerHandshakeTests {
    @Test("stable signaling drops answer without handshake")
    func stableSignalingDropsAnswerWithoutHandshake() throws {
        let exchange = try source("Sources/PQSRTC/RTCSession+Exchange.swift")
        #expect(exchange.contains("return .dropped"))
        #expect(exchange.contains("enum RemoteDescriptionApplyResult"))

        let handleAnswer = try sourceBody(of: "handleAnswer", in: exchange)
        #expect(handleAnswer.contains("remoteApplyResult"))
        #expect(handleAnswer.contains("guard remoteApplyResult == .applied else { return }"))
        #expect(!handleAnswer.contains("throw RTCErrors") || handleAnswer.contains("guard remoteApplyResult == .applied else { return }"))
    }

    private func source(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func sourceBody(of functionName: String, in source: String) throws -> String {
        try SourceContract.sourceBody(of: functionName, in: source)
    }
}
