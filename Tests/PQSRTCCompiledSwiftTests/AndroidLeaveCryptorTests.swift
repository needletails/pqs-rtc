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
        #expect(native.contains("fun disposeReceiverCryptors(forParticipant participantId: String)"))
        let client = try source("Sources/PQSRTC/Android/AndroidRTCClient.swift")
        #expect(client.contains("func disposeReceiverCryptors(forParticipant"))
    }

    @Test("setFrameEncryptionKey canonicalizes participant id")
    func setFrameEncryptionKeyCanonicalizesParticipantId() throws {
        let cipher = try source("Sources/PQSRTC/RTCSession+RTCCipherTransport.swift")
        let body = try SourceContract.sourceBody(of: "setFrameEncryptionKey", in: cipher)
        #expect(body.contains("conferenceParticipantIdentityKey(participantId)"))
    }

    private func source(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
