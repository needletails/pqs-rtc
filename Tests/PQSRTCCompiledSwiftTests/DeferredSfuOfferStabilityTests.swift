import Foundation
import Testing

@testable import PQSRTC

@Suite(.serialized)
struct DeferredSfuOfferStabilityTests {
    @Test("have-local-offer keeps deferred offer queued on Android")
    func haveLocalOfferKeepsDeferredOfferQueuedOnAndroid() throws {
        let exchange = try source("Sources/PQSRTC/RTCSession+Exchange.swift")
        let process = try sourceBody(of: "processDeferredSfuRenegotiationOfferIfNeeded", in: exchange)
        #expect(process.contains("signalingStateByConnectionId"))
        #expect(process.contains("pendingDeferredSfuRenegotiationOffers[normId] = pending"))
        #expect(process.contains("cachedSignalingState"))
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
