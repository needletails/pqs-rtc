import Foundation
import Testing

@testable import PQSRTC

@Suite(.serialized)
struct CallConferenceTests {

    // MARK: - conferencePassword property

    @Test("conferencePassword defaults to nil")
    func conferencePasswordDefaultsNil() throws {
        let sender = try Call.Participant(secretName: "alice", nickname: "Alice", deviceId: "d1")
        let recipient = try Call.Participant(secretName: "bob", nickname: "Bob", deviceId: "d2")
        let call = try Call(
            sharedCommunicationId: "comm-1",
            sender: sender,
            recipients: [recipient]
        )
        #expect(call.conferencePassword == nil)
    }

    @Test("conferencePassword can be set and read back")
    func conferencePasswordRoundTrip() throws {
        let sender = try Call.Participant(secretName: "alice", nickname: "Alice", deviceId: "d1")
        let recipient = try Call.Participant(secretName: "bob", nickname: "Bob", deviceId: "d2")
        var call = try Call(
            sharedCommunicationId: "comm-2",
            sender: sender,
            recipients: [recipient]
        )
        call.conferencePassword = "secret123"
        #expect(call.conferencePassword == "secret123")
    }

    @Test("conferencePassword survives Codable round-trip")
    func conferencePasswordCodable() throws {
        let sender = try Call.Participant(secretName: "alice", nickname: "Alice", deviceId: "d1")
        let recipient = try Call.Participant(secretName: "bob", nickname: "Bob", deviceId: "d2")
        var original = try Call(
            sharedCommunicationId: "comm-codable",
            sender: sender,
            recipients: [recipient]
        )
        original.conferencePassword = "round-trip-pass"

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(Call.self, from: data)

        #expect(decoded.conferencePassword == "round-trip-pass")
    }

    @Test("conferencePassword nil survives Codable round-trip")
    func conferencePasswordNilCodable() throws {
        let sender = try Call.Participant(secretName: "alice", nickname: "Alice", deviceId: "d1")
        let recipient = try Call.Participant(secretName: "bob", nickname: "Bob", deviceId: "d2")
        let original = try Call(
            sharedCommunicationId: "comm-nil-codable",
            sender: sender,
            recipients: [recipient]
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(Call.self, from: data)

        #expect(decoded.conferencePassword == nil)
    }

    // MARK: - Relaxed recipients validation

    @Test("Call init allows empty recipients for conference use")
    func emptyRecipientsAllowed() throws {
        let sender = try Call.Participant(secretName: "alice", nickname: "Alice", deviceId: "d1")
        let call = try Call(
            sharedCommunicationId: "#conf-ABCDEF",
            channelWireId: "#conf-ABCDEF",
            sender: sender,
            recipients: []
        )
        #expect(call.recipients.isEmpty)
        #expect(call.sharedCommunicationId == "#conf-ABCDEF")
    }

    @Test("Call init still rejects empty sharedCommunicationId")
    func emptyCommIdStillRejected() throws {
        let sender = try Call.Participant(secretName: "alice", nickname: "Alice", deviceId: "d1")
        #expect(throws: Error.self) {
            _ = try Call(sharedCommunicationId: " ", sender: sender, recipients: [])
        }
    }

    @Test("groupSharedCommunicationId init still allows empty recipients")
    func groupInitEmptyRecipients() throws {
        let sender = try Call.Participant(secretName: "alice", nickname: "Alice", deviceId: "d1")
        let call = try Call(
            groupSharedCommunicationId: "some-group-room",
            sender: sender,
            recipients: []
        )
        #expect(call.recipients.isEmpty)
        #expect(call.sharedCommunicationId == "some-group-room")
    }

    // MARK: - resolvedChannelWireId behavior for conference rooms

    @Test("resolvedChannelWireId returns value for conference-style room IDs")
    func resolvedChannelWireIdForConference() throws {
        let sender = try Call.Participant(secretName: "alice", nickname: "Alice", deviceId: "d1")
        let call = try Call(
            sharedCommunicationId: "#conf-ABCDEF",
            channelWireId: "#conf-ABCDEF",
            sender: sender,
            recipients: []
        )
        // conf-ABCDEF is not a UUID, so resolvedChannelWireId should return the value
        #expect(call.resolvedChannelWireId == "#conf-ABCDEF")
    }

    @Test("resolvedChannelWireId returns nil for ephemeral UUID rooms")
    func resolvedChannelWireIdForEphemeralUUID() throws {
        let sender = try Call.Participant(secretName: "alice", nickname: "Alice", deviceId: "d1")
        let recipient = try Call.Participant(secretName: "bob", nickname: "Bob", deviceId: "d2")
        let uuid = UUID().uuidString
        let call = try Call(
            sharedCommunicationId: "#\(uuid)",
            channelWireId: "#\(uuid)",
            sender: sender,
            recipients: [recipient]
        )
        #expect(call.resolvedChannelWireId == nil)
    }

    // MARK: - Screen share permission scope

    @Test("screen share permissions are not enforced for direct one-to-one calls")
    func screenSharePermissionScopeAllowsDirectOneToOne() throws {
        let sender = try Call.Participant(secretName: "alice", nickname: "Alice", deviceId: "d1")
        let recipient = try Call.Participant(secretName: "bob", nickname: "Bob", deviceId: "d2")
        let call = try Call(sharedCommunicationId: UUID().uuidString, sender: sender, recipients: [recipient])

        #expect(RTCSession.shouldEnforceScreenShareConferencePermissions(call: call, permissions: ConferencePermissions()) == false)
    }

    @Test("screen share permissions are enforced for conferences")
    func screenSharePermissionScopeEnforcesConference() throws {
        let sender = try Call.Participant(secretName: "alice", nickname: "Alice", deviceId: "d1")
        var call = try Call(
            sharedCommunicationId: "#conf-ABCDEF",
            channelWireId: "#conf-ABCDEF",
            sender: sender,
            recipients: []
        )
        call.conferencePassword = "secret"

        #expect(RTCSession.shouldEnforceScreenShareConferencePermissions(call: call, permissions: ConferencePermissions()) == true)
    }

    @Test("screen share permissions are enforced once roles are known")
    func screenSharePermissionScopeEnforcesKnownRoles() throws {
        let sender = try Call.Participant(secretName: "alice", nickname: "Alice", deviceId: "d1")
        let recipient = try Call.Participant(secretName: "bob", nickname: "Bob", deviceId: "d2")
        let call = try Call(sharedCommunicationId: "#team", channelWireId: "#team", sender: sender, recipients: [recipient])
        let permissions = ConferencePermissions(localRole: .viewer, participantRoles: ["alice": .viewer])

        #expect(RTCSession.shouldEnforceScreenShareConferencePermissions(call: call, permissions: permissions) == true)
    }

    @Test("screen share participant ids normalize add and remove keys")
    func screenShareParticipantIdsNormalizeAddAndRemoveKeys() {
        #expect(RTCSession.resolvedScreenShareParticipantId(
            streamIds: ["screen_echo"],
            trackId: "screen_echo_#conf-room",
            fallback: "#conf-room"
        ) == "echo")
        #expect(RTCSession.participantIdFromScreenShareId("screen_echo") == "echo")
    }

    @Test("screen share system audio egress is explicit when unsupported")
    func screenShareSystemAudioEgressIsExplicitWhenUnsupported() {
        #expect(RTCSession.supportsScreenShareSystemAudioEgress == false)
    }

    @Test("conference role updates preserve server timing and normalize participant keys")
    func conferenceRoleUpdatesPreserveTimingAndNormalizeKeys() async {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)
        defer { Task { await session.shutdown(with: nil) } }

        let timing = ConferenceTiming(
            conferenceStartedAtEpochSeconds: 100,
            serverTimestampEpochSeconds: 160,
            conferenceDurationSeconds: 60
        )

        await session.updateConferenceRoles(
            localUsername: "nudge",
            participantRoles: ["nudge": "host", "echo": "viewer"],
            timing: timing
        )
        await session.mergeConferenceParticipants(
            localUsername: "nudge",
            activeRemoteParticipants: ["echo_", "screen_echo"],
            localDefaultRole: .viewer
        )
        await session.updateConferenceRoles(
            localUsername: "nudge_",
            participantRoles: ["nudge": "host", "echo": "cohost"],
            timing: nil
        )

        let permissions = await session.conferencePermissions
        #expect(permissions.localRole == .host)
        #expect(permissions.participantRoles["echo"] == .cohost)
        #expect(permissions.participantRoles.keys.filter { RTCSession.conferenceParticipantIdentityKey($0) == "echo" }.count == 1)
        #expect(permissions.timing == timing)
    }
}
