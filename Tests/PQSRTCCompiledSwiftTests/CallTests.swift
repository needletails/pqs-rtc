import Foundation
import Testing

@testable import PQSRTC

@Suite
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

        #expect(throws: Error.self) {
            _ = try Call(sharedCommunicationId: "comm", sender: sender, recipients: [])
        }
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
}
