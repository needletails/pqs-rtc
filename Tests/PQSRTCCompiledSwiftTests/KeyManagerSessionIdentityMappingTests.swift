import DoubleRatchetKit
import Foundation
import Crypto
import Testing

@testable import PQSRTC

@Suite(.serialized)
struct KeyManagerSessionIdentityMappingTests {
    private func serverCompositeSfuSessionId(
        roomId: String,
        deviceId: UUID,
        sessionContext: String?
    ) -> UUID {
        let normalizedContext = sessionContext?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let base = "\(roomId.normalizedUUIDConnectionId.lowercased())|\(deviceId.uuidString)"
        let input = normalizedContext?.isEmpty == false
            ? "\(base)|\(normalizedContext!)"
            : base
        let digest = SHA256.hash(data: Data(input.utf8))
        let bytes = Array(digest)
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

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
    func recipientIdentityDerivesStableSessionIdentityId_whenConnectionIdIsShortConferenceRoom() async throws {
        let keyManager = KeyManager()
        let connectionId = "#conf-k7m2x9q4r8vd6p3t-uk7m2x9q4r8vd6"
        let normalizedConnectionId = "k7m2x9q4r8vd6p3t-uk7m2x9q4r8vd6"
        let expectedSessionId = normalizedConnectionId.stableUUIDConnectionId

        let local = try await keyManager.generateSenderIdentity(connectionId: connectionId, secretName: "alice")
        let recipientProps = await local.sessionIdentity.props(symmetricKey: local.symmetricKey)
        #expect(recipientProps != nil)
        #expect(local.sessionIdentity.id == expectedSessionId)

        guard let recipientProps else { return }

        let recipientIdentity = try await keyManager.createRecipientIdentity(connectionId: connectionId, props: recipientProps)
        #expect(recipientIdentity.sessionIdentity.id == expectedSessionId)
        let fetchedByRoute = await keyManager.fetchConnectionIdentityByConnectionId(connectionId)
        let fetchedByNormalized = await keyManager.fetchConnectionIdentityByConnectionId(normalizedConnectionId)
        let fetchedBySessionId = await keyManager.fetchConnectionIdentity(expectedSessionId)
        #expect(fetchedByRoute?.sessionIdentity.id == expectedSessionId)
        #expect(fetchedByNormalized?.sessionIdentity.id == expectedSessionId)
        #expect(fetchedBySessionId?.connectionId == connectionId)
    }

    @Test
    func sfuRecipientIdentityMatchesServerCompositeSessionId_andKeepsRoomLookupAliases() async throws {
        let keyManager = KeyManager()
        let roomId = "493B6051-39F0-493D-AACE-7683F2BFA9E2"
        let channelWireId = "#broken_493b6051-39f0-493d-aace-7683f2bfa9e2"
        let deviceId = try #require(UUID(uuidString: "2D4087FD-0E8A-4D96-B558-33142F345AD2"))
        let sessionContext = "A6CDC6A2-4C89-4649-B593-77CED9458EEF"
        let expectedSessionId = serverCompositeSfuSessionId(
            roomId: roomId,
            deviceId: deviceId,
            sessionContext: sessionContext
        )
        #expect(expectedSessionId == UUID(uuidString: "DDDB1A3D-B680-26B0-C2AD-BD0001E55020"))

        let local = try await keyManager.generateSenderIdentity(connectionId: UUID().uuidString, secretName: "sfu")
        let recipientProps = await local.sessionIdentity.props(symmetricKey: local.symmetricKey)
        #expect(recipientProps != nil)
        guard let recipientProps else { return }

        let recipientIdentity = try await keyManager.createSFUSignalingRecipientIdentity(
            roomId: roomId,
            deviceId: deviceId,
            sessionContext: sessionContext,
            props: recipientProps,
            aliases: [roomId, channelWireId]
        )

        #expect(recipientIdentity.connectionId == "\(roomId.normalizedUUIDConnectionId.lowercased())|\(deviceId.uuidString)")
        #expect(recipientIdentity.sessionIdentity.id == expectedSessionId)

        let fetchedByRoom = await keyManager.fetchConnectionIdentityByConnectionId(roomId)
        let fetchedByChannel = await keyManager.fetchConnectionIdentityByConnectionId(channelWireId)
        let fetchedByComposite = await keyManager.fetchConnectionIdentityByConnectionId(recipientIdentity.connectionId)
        let fetchedBySessionId = await keyManager.fetchConnectionIdentity(expectedSessionId)

        #expect(fetchedByRoom?.sessionIdentity.id == expectedSessionId)
        #expect(fetchedByChannel?.sessionIdentity.id == expectedSessionId)
        #expect(fetchedByComposite?.sessionIdentity.id == expectedSessionId)
        #expect(fetchedBySessionId?.sessionIdentity.id == expectedSessionId)
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
