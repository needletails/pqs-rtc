import Foundation
import Testing

@testable import PQSRTC

@Suite(.serialized)
struct SessionTeardownResetTests {
    @Test("finishEndConnection clears deferred offers and groupCalls")
    func finishEndConnectionClearsDeferredOffersAndGroupCalls() throws {
        let peer = try source("Sources/PQSRTC/RTCSession+PeerConnection.swift")
        #expect(peer.contains("pendingDeferredSfuRenegotiationOffers.removeAll()"))
        #expect(peer.contains("groupCalls.removeAll()"))
        #expect(peer.contains("mediaDelegate = nil"))
        #expect(peer.contains("clearAndroidSessionRemoteAudioResolvedTrackIdsForNewCall()"))
    }

    @Test("shutdown uses force true so duplicate end still resets")
    func shutdownForceTrueClearsEvenAfterDuplicateEnd() throws {
        let peer = try source("Sources/PQSRTC/RTCSession+PeerConnection.swift")
        let shutdown = try sourceBody(of: "shutdown", in: peer)
        #expect(shutdown.contains("finishEndConnection(currentCall: call, force: true"))
        #expect(peer.contains("_ = beginEnding(connectionId: connectionIdKey)"))
        #expect(peer.contains("_ = beginEnding(callKey: callKey)"))
    }

    @Test("answerCall resets attempt flags")
    func answerCallResetsAttemptFlags() throws {
        let oneToOne = try source("Sources/PQSRTC/RTCSession+OneToOneCall.swift")
        let answer = try sourceBody(of: "answerCall", in: oneToOne)
        #expect(answer.contains("resetAttemptFlagsForNewCall(connectionId:"))
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
