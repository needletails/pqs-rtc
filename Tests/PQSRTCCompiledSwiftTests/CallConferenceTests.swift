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
}
