import Foundation
import Testing

@testable import PQSRTC

@Suite
struct ConnectionIdentityTests {
    @Test
    func connectionLocalIdentityStoresValues() async throws {
        let keyManager = KeyManager()
        let local = try await keyManager.generateSenderIdentity(connectionId: "conn-1", secretName: "alice")

        let identity = ConnectionLocalIdentity(
            connectionId: local.connectionId,
            localKeys: local.localKeys,
            symmetricKey: local.symmetricKey,
            sessionIdentity: local.sessionIdentity
        )

        #expect(identity.connectionId == "conn-1")

        let props = await identity.sessionIdentity.props(symmetricKey: identity.symmetricKey)
        #expect(props != nil)
        #expect(props?.secretName == "alice")
    }

    @Test
    func connectionSessionIdentityCiphertextDefaultsNil_andIsMutable() async throws {
        let keyManager = KeyManager()
        let local = try await keyManager.generateSenderIdentity(connectionId: "conn-2", secretName: "bob")

        var identity = ConnectionSessionIdentity(
            connectionId: "conn-2",
            symmetricKey: local.symmetricKey,
            sessionIdentity: local.sessionIdentity
        )

        #expect(identity.ciphertext == nil)

        let data = Data([0xAA, 0xBB])
        identity.ciphertext = data

        #expect(identity.ciphertext == data)
    }
}
