import Foundation
import Testing

@testable import PQSRTC

@Suite(.serialized)
struct AndroidLeaveCryptorTests {
    @Test("remove participant disposes native cryptors and audio maps")
    func removeParticipantDisposesNativeCryptorsAndAudioMaps() throws {
        let group = try source("Sources/PQSRTC/RTCSession+GroupCall.swift")
        #expect(group.contains("remoteAudioTracksByParticipantId"))
        #expect(group.contains("disposeReceiverCryptors(forParticipant:"))

        let native = try source("Sources/PQSRTC/Skip/AndroidRTCNativeSupport.kt")
        #expect(native.contains("fun disposeReceiverCryptors(forParticipant: String)"))
        let client = try source("Sources/PQSRTC/Android/AndroidRTCClient.swift")
        #expect(client.contains("func disposeReceiverCryptors(forParticipant"))
    }

    @Test("setFrameEncryptionKey canonicalizes participant id")
    func setFrameEncryptionKeyCanonicalizesParticipantId() throws {
        let cipher = try source("Sources/PQSRTC/RTCSession+RTCCipherTransport.swift")
        let body = try SourceContract.sourceBody(of: "setFrameEncryptionKey", in: cipher)
        #expect(body.contains("conferenceParticipantIdentityKey(participantId)"))
    }

    @Test("hangup wipes Android FrameCryptorKeyProvider; ICE retry keeps it")
    func hangupWipesAndroidKeyProviderIceRetryKeepsIt() throws {
        let client = try source("Sources/PQSRTC/Android/AndroidRTCClient.swift")
        let shutdown = try source("Sources/PQSRTC/RTCSession+PeerConnection.swift")
        let ice = try source("Sources/PQSRTC/RTCSession+IceFallback.swift")

        #expect(client.contains("func resetFrameKeyProviderForHangup()"))
        #expect(client.contains("frameCryptorSupport.clearKeyProvider()"))
        #expect(client.contains("keyProviderReady = false"))
        #expect(client.contains("pendingPerParticipantKeys.removeAll()"))

        let retryBody = try SourceContract.sourceBody(of: "resetPeerConnectionForRetry", in: client)
        #expect(retryBody.contains("frameCryptorSupport.disposeAll()"))
        #expect(!retryBody.contains("clearKeyProvider()"))
        #expect(!retryBody.contains("resetFrameKeyProviderForHangup()"))

        #expect(shutdown.contains("resetFrameKeyProviderForHangup()"))
        #expect(shutdown.contains("prepareCryptoStackForNextCallIfNeeded()"))
        #expect(shutdown.contains("clearAndroidSessionRemoteAudioResolvedTrackIdsForNewCall()"))
        #expect(shutdown.contains("androidRemoteAudioResolvedTrackIdsByParticipantId.removeAll()"))

        let iceReset = try SourceContract.sourceBody(of: "resetAttemptFlagsForNewCall", in: ice)
        #expect(iceReset.contains("clearAndroidSessionRemoteAudioResolvedTrackIdsForNewCall()"))

        let cipher = try source("Sources/PQSRTC/RTCSession+RTCCipherTransport.swift")
        #expect(cipher.contains("func resetFrameEncryptionKeyProviderForNewCallAttempt()"))
        #expect(cipher.contains("resetFrameKeyProviderForHangup()"))
        #expect(cipher.contains("clearAndroidSessionRemoteAudioResolvedTrackIdsForNewCall()"))

        let iceRetryBody = try SourceContract.sourceBody(of: "discardPeerConnectionAttemptForRetry", in: ice)
        #expect(iceRetryBody.contains("resetPeerConnectionForRetry()"))
        #expect(!iceRetryBody.contains("resetFrameKeyProviderForHangup()"))
        #expect(!iceRetryBody.contains("clearAndroidSessionRemoteAudioResolvedTrackIdsForNewCall()"))
    }

    private func source(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
