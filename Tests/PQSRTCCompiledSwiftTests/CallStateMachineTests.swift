import Foundation
import Testing

@testable import PQSRTC

@Suite
struct CallStateMachineTests {
    @Test
    func enumsCodableRoundTrip() throws {
        for callType in [CallStateMachine.CallType.voice, CallStateMachine.CallType.video] {
            let data = try JSONEncoder().encode(callType)
            let decoded = try JSONDecoder().decode(CallStateMachine.CallType.self, from: data)
            #expect(callType == decoded)
        }

        let inbound = CallStateMachine.CallDirection.inbound(.voice)
        let outbound = CallStateMachine.CallDirection.outbound(.video)

        let inboundData = try JSONEncoder().encode(inbound)
        let outboundData = try JSONEncoder().encode(outbound)

        let inboundDecoded = try JSONDecoder().decode(CallStateMachine.CallDirection.self, from: inboundData)
        let outboundDecoded = try JSONDecoder().decode(CallStateMachine.CallDirection.self, from: outboundData)

        #expect(inbound.description == inboundDecoded.description)
        #expect(outbound.description == outboundDecoded.description)

        let endStates: [CallStateMachine.EndState] = [
            .userInitiated,
            .partnerInitiated,
            .userInitiatedUnanswered,
            .partnerInitiatedUnanswered,
            .partnerInitiatedRejected,
            .failed,
            .auxialaryDevcieAnswered
        ]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for endState in endStates {
            let data = try encoder.encode(endState)
            let decoded = try decoder.decode(CallStateMachine.EndState.self, from: data)
            #expect(!String(data: data, encoding: .utf8)!.isEmpty)
            let reencoded = try encoder.encode(decoded)
            #expect(reencoded == data)
        }
    }

    @Test
    func stateCodableRoundTrip() throws {
        let sender = try Call.Participant(secretName: "s", nickname: "S", deviceId: "sd")
        let recipient = try Call.Participant(secretName: "r", nickname: "R", deviceId: "rd")
        let call = try Call(sharedCommunicationId: "comm", sender: sender, recipients: [recipient])

        let states: [CallStateMachine.State] = [
            .waiting,
            .ready(call),
            .connecting(.inbound(.voice), call),
            .connected(.outbound(.video), call),
            .held(nil, call),
            .ended(.userInitiated, call),
            .failed(nil, call, "oops"),
            .callAnsweredAuxDevice(call)
        ]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for state in states {
            let data = try encoder.encode(state)
            let decoded = try decoder.decode(CallStateMachine.State.self, from: data)
            #expect(state.description == decoded.description)
        }
    }

    @Test
    func transitionSkipsDuplicate() async throws {
        let sm = CallStateMachine()
        let sender = try Call.Participant(secretName: "s", nickname: "S", deviceId: "sd")
        let recipient = try Call.Participant(secretName: "r", nickname: "R", deviceId: "rd")
        let call = try Call(sharedCommunicationId: "comm", sender: sender, recipients: [recipient])

        await sm.transition(to: .ready(call))
        let prev = await sm.currentState

        await sm.transition(to: .ready(call))
        let now = await sm.currentState

        #expect(prev?.description == now?.description)
    }
}
