import DoubleRatchetKit
import Foundation
import Testing

@testable import PQSRTC

@Suite(.serialized)
struct KeyManagerSessionIdentityMappingTests {
    @Test
    func recipientIdentityUsesConnectionIdAsSessionIdentityId_whenConnectionIdIsUUIDString() async throws {
        let keyManager = KeyManager()

        let connectionUUID = UUID()
        let connectionId = connectionUUID.uuidString

        // Use locally-generated props as deterministic input.
        let local = try await keyManager.generateSenderIdentity(connectionId: UUID().uuidString, secretName: "alice")
        let recipientProps = await local.sessionIdentity.props(symmetricKey: local.symmetricKey)
        #expect(recipientProps != nil)

        guard let recipientProps else { return }

        let recipientIdentity = try await keyManager.createRecipientIdentity(connectionId: connectionId, props: recipientProps)
        #expect(recipientIdentity.connectionId == connectionId)
        #expect(recipientIdentity.sessionIdentity.id == connectionUUID)

        let fetchedByConnectionId = await keyManager.fetchConnectionIdentityByConnectionId(connectionId)
        #expect(fetchedByConnectionId != nil)
        #expect(fetchedByConnectionId?.sessionIdentity.id == connectionUUID)

        let fetchedByUUID = await keyManager.fetchConnectionIdentity(connectionUUID)
        #expect(fetchedByUUID != nil)
        #expect(fetchedByUUID?.connectionId == connectionId)

        let fetchedSessionIdentity = await keyManager.fetchSessionIdentity(connectionUUID)
        #expect(fetchedSessionIdentity != nil)
        #expect(fetchedSessionIdentity?.id == connectionUUID)
    }

    @Test
    func updateSessionIdentityPersistsToStoredConnectionIdentity() async throws {
        let keyManager = KeyManager()

        let connectionUUID = UUID()
        let connectionId = connectionUUID.uuidString

        let local = try await keyManager.generateSenderIdentity(connectionId: UUID().uuidString, secretName: "alice")
        let recipientProps = await local.sessionIdentity.props(symmetricKey: local.symmetricKey)
        #expect(recipientProps != nil)

        guard let recipientProps else { return }

        _ = try await keyManager.createRecipientIdentity(connectionId: connectionId, props: recipientProps)
        let existing = await keyManager.fetchConnectionIdentityByConnectionId(connectionId)
        #expect(existing != nil)

        guard let existing else { return }

        // Create a new props payload to ensure we can observe the update.
        let updatedProps = SessionIdentity.UnwrappedProps(
            secretName: recipientProps.secretName,
            deviceId: recipientProps.deviceId,
            sessionContextId: recipientProps.sessionContextId,
            longTermPublicKey: recipientProps.longTermPublicKey,
            signingPublicKey: recipientProps.signingPublicKey,
            mlKEMPublicKey: recipientProps.mlKEMPublicKey,
            oneTimePublicKey: recipientProps.oneTimePublicKey,
            deviceName: "updated-device",
            isMasterDevice: recipientProps.isMasterDevice
        )

        let updatedIdentity = try SessionIdentity(
            id: connectionUUID,
            props: updatedProps,
            symmetricKey: existing.symmetricKey
        )

        try await keyManager.updateSessionIdentity(updatedIdentity)

        let fetched = await keyManager.fetchConnectionIdentityByConnectionId(connectionId)
        #expect(fetched != nil)

        let fetchedProps = await fetched?.sessionIdentity.props(symmetricKey: fetched?.symmetricKey ?? existing.symmetricKey)
        #expect(fetchedProps?.deviceName == "updated-device")
    }

    @Test
    func removeSessionIdentityRemovesStoredConnectionIdentity_whenKeyedByUUIDString() async throws {
        let keyManager = KeyManager()

        let connectionUUID = UUID()
        let connectionId = connectionUUID.uuidString

        let local = try await keyManager.generateSenderIdentity(connectionId: UUID().uuidString, secretName: "alice")
        let recipientProps = await local.sessionIdentity.props(symmetricKey: local.symmetricKey)
        #expect(recipientProps != nil)

        guard let recipientProps else { return }

        _ = try await keyManager.createRecipientIdentity(connectionId: connectionId, props: recipientProps)
        #expect(await keyManager.fetchConnectionIdentityByConnectionId(connectionId) != nil)

        await keyManager.removeSessionIdentity(connectionUUID)
        #expect(await keyManager.fetchConnectionIdentityByConnectionId(connectionId) == nil)
    }
}
