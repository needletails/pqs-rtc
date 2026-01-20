import DoubleRatchetKit
import Foundation
import Testing

@testable import PQSRTC

@Suite(.serialized)
struct KeyManagerTests {
    @Test
    func generateSenderIdentityStoresBundle() async throws {
        let keyManager = KeyManager()
        let identity = try await keyManager.generateSenderIdentity(connectionId: "conn-1", secretName: "alice")

        #expect(identity.connectionId == "conn-1")

        let fetched = try await keyManager.fetchCallKeyBundle()
        #expect(fetched != nil)
        #expect(fetched?.connectionId == "conn-1")

        let props = await identity.sessionIdentity.props(symmetricKey: identity.symmetricKey)
        #expect(props != nil)
        #expect(props?.secretName == "alice")
    }

    @Test
    func recipientIdentityAttachesPendingCiphertext() async throws {
        let keyManager = KeyManager()
        let ciphertext = "ciphertext".data(using: .utf8)!
        await keyManager.storeCiphertext(connectionId: "conn-2", ciphertext: ciphertext)

        let local = try await keyManager.generateSenderIdentity(connectionId: "local", secretName: "local")
        let recipientProps = await local.sessionIdentity.props(symmetricKey: local.symmetricKey)
        #expect(recipientProps != nil)

        guard let recipientProps else { return }

        let recipientIdentity = try await keyManager.createRecipientIdentity(connectionId: "conn-2", props: recipientProps)
        #expect(recipientIdentity.connectionId == "conn-2")

        let storedCiphertext = await keyManager.fetchCiphertext(connectionId: "conn-2")
        #expect(storedCiphertext == ciphertext)
    }

    @Test
    func oneTimeKeyStoreRoundTrip() async throws {
        let keyManager = KeyManager()

        let otpk = Curve25519.KeyAgreement.PrivateKey()
        let id = UUID()
        let stored = try DoubleRatchetKit.CurvePrivateKey(id: id, otpk.rawRepresentation)
        await keyManager.storeOneTimeKey(stored, id: id)

        let fetched = try await keyManager.fetchOneTimePrivateKey(id)
        #expect(fetched != nil)
        #expect(fetched?.id == id)
    }
}
