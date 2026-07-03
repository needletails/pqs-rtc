import Foundation
import Testing

@testable import PQSRTC

@Suite(.serialized)
struct CallTests {
    @Test
    func participantInitValidation() throws {
        let p = try Call.Participant(secretName: "alice", nickname: "Alice", deviceId: "dev1")
        #expect(p.secretName == "alice")
        #expect(p.nickname == "Alice")
        #expect(p.deviceId == "dev1")

        #expect(throws: Error.self) {
            _ = try Call.Participant(secretName: " ", nickname: "n", deviceId: "d")
        }

        #expect(throws: Error.self) {
            _ = try Call.Participant(secretName: "s", nickname: "", deviceId: "d")
        }
    }

    @Test
    func callInitValidation() throws {
        let sender = try Call.Participant(secretName: "s", nickname: "S", deviceId: "sd")
        let recipient = try Call.Participant(secretName: "r", nickname: "R", deviceId: "rd")

        let call = try Call(
            sharedCommunicationId: "comm",
            sender: sender,
            recipients: [recipient],
            supportsVideo: true,
            isActive: true
        )

        #expect(call.sharedCommunicationId == "comm")
        #expect(call.supportsVideo == true)
        #expect(call.isActive == true)

        #expect(throws: Error.self) {
            _ = try Call(sharedCommunicationId: " ", sender: sender, recipients: [recipient])
        }

        // Empty recipients is allowed (conference calls join before participants are known).
        let emptyRecipientsCall = try Call(sharedCommunicationId: "comm", sender: sender, recipients: [])
        #expect(emptyRecipientsCall.recipients.isEmpty)
    }

    @Test
    func endCallUpdatesFlagsAndDuration() throws {
        let sender = try Call.Participant(secretName: "s", nickname: "S", deviceId: "sd")
        let recipient = try Call.Participant(secretName: "r", nickname: "R", deviceId: "rd")

        var call = try Call(
            sharedCommunicationId: "comm",
            sender: sender,
            recipients: [recipient],
            createdAt: Date(timeIntervalSince1970: 1_000),
            isActive: true
        )

        #expect(call.hasEnded == false)
        #expect(call.isTerminal == false)

        call.endCall(endState: .unanswered)

        #expect(call.hasEnded == true)
        #expect(call.isTerminal == true)
        #expect(call.unanswered == true)
        #expect(call.endedAt != nil)
        #expect(call.duration != nil)
    }

    @Test
    func callEqualityComparesFrameIdentityKeyMaterial() async throws {
        let keyManager = KeyManager()
        let localIdentity = try await keyManager.generateSenderIdentity(connectionId: "conn-call-equality", secretName: "alice")
        guard let frameProps = await localIdentity.sessionIdentity.props(symmetricKey: localIdentity.symmetricKey) else {
            Issue.record("Expected generated identity props")
            return
        }
        guard !frameProps.longTermPublicKey.isEmpty else {
            Issue.record("Expected generated identity props to include long-term key material")
            return
        }

        var changedFrameProps = frameProps
        var changedLongTermPublicKey = Array(changedFrameProps.longTermPublicKey)
        changedLongTermPublicKey[0] ^= 0x01
        changedFrameProps.setLongTermPublicKey(Data(changedLongTermPublicKey))

        let sender = try Call.Participant(secretName: "alice", nickname: "Alice", deviceId: "dev-a")
        let recipient = try Call.Participant(secretName: "bob", nickname: "Bob", deviceId: "dev-b")
        let id = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_234)

        let lhs = try Call(
            id: id,
            sharedCommunicationId: "comm-call-equality",
            sender: sender,
            recipients: [recipient],
            createdAt: createdAt,
            frameIdentityProps: frameProps
        )
        let rhs = try Call(
            id: id,
            sharedCommunicationId: "comm-call-equality",
            sender: sender,
            recipients: [recipient],
            createdAt: createdAt,
            frameIdentityProps: changedFrameProps
        )

        #expect(frameProps.deviceId == changedFrameProps.deviceId)
        #expect(lhs != rhs)
    }

    @Test
    func groupCallConnectionIdDetection() {
        #expect("#room".isGroupCall)
        #expect("#conf-7dd14337-c20e-436e-9220-40ea234cafa6".isGroupCall)
        #expect("conf-7dd14337-c20e-436e-9220-40ea234cafa6".isGroupCall)
        #expect("conf-7dd14337-c20e-436e-9220-40ea234cafa6".normalizedConnectionId.isGroupCall)
        #expect(!"7dd14337-c20e-436e-9220-40ea234cafa6".isGroupCall)
        #expect(!"alice".isGroupCall)
    }
}
