import DoubleRatchetKit
import Foundation
import Testing

@testable import PQSRTC

@Suite
struct RTCSessionValidationAndShutdownTests {
    @Test
    func createCryptoSessionThrowsWhenIdentityPropsMissing() async throws {
        let sender = try Call.Participant(secretName: "s", nickname: "S", deviceId: "sd")
        let recipient = try Call.Participant(secretName: "r", nickname: "R", deviceId: "rd")
        let call = try Call(
            sharedCommunicationId: UUID().uuidString,
            sender: sender,
            recipients: [recipient],
            supportsVideo: false,
            isActive: true
        )

        let session = RTCSession(
            iceServers: ["stun:stun.l.google.com:19302"],
            username: "",
            password: "",
            delegate: nil
        )

        var thrownEncryptionError: EncryptionErrors?
        do {
            try await session.createCryptoSession(with: call)
        } catch let error as EncryptionErrors {
            thrownEncryptionError = error
        } catch {
            throw error
        }

        #expect(thrownEncryptionError == .missingProps, "Expected .missingProps but got \(String(describing: thrownEncryptionError))")

        await session.shutdown(with: nil)
    }

    @Test
    func shutdownClearsKeyManagerState() async throws {
        let session = RTCSession(
            iceServers: ["stun:stun.l.google.com:19302"],
            username: "",
            password: "",
            delegate: nil
        )

        // Populate KeyManager with representative state.
        let local = try await session.keyManager.generateSenderIdentity(connectionId: UUID().uuidString, secretName: "alice")
        let props = await local.sessionIdentity.props(symmetricKey: local.symmetricKey)
        #expect(props != nil)

        if let props {
            _ = try await session.keyManager.createRecipientIdentity(connectionId: UUID().uuidString, props: props)
        }

        let otpk = Curve25519.KeyAgreement.PrivateKey()
        let otpkId = UUID()
        let stored = try DoubleRatchetKit.CurvePrivateKey(id: otpkId, otpk.rawRepresentation)
        await session.keyManager.storeOneTimeKey(stored, id: otpkId)

        await session.keyManager.storeCiphertext(connectionId: "conn-pending", ciphertext: Data([0x01, 0x02, 0x03]))

        #expect(await session.keyManager.oneTimeKeyCount() > 0)
        #expect(await session.keyManager.sessionIdentityCount() > 0)
        #expect((try await session.keyManager.fetchCallKeyBundle()) != nil)
        #expect(await session.keyManager.fetchCiphertext(connectionId: "conn-pending") != nil)

        await session.shutdown(with: nil)

        #expect(await session.keyManager.oneTimeKeyCount() == 0)
        #expect(await session.keyManager.sessionIdentityCount() == 0)
        #expect((try await session.keyManager.fetchCallKeyBundle()) == nil)
        #expect(await session.keyManager.fetchCiphertext(connectionId: "conn-pending") == nil)
    }
}
