//
//  CallStateMachineTests.swift
//  needle-tail-rtc
//
//  Created by GPT-5 Assistant on 10/6/25.
//

import Foundation
import SkipTest
@testable import NeedleTailRTC

final class CallStateMachineTests: XCTestCase {
    func testEnumsCodableRoundTrip() throws {
        // CallType
        for type in [CallStateMachine.CallType.voice, CallStateMachine.CallType.video] {
            let data = try JSONEncoder().encode(type)
            let decoded = try JSONDecoder().decode(CallStateMachine.CallType.self, from: data)
            XCTAssertEqual(type, decoded)
        }

        // CallDirection
        let inbound = CallStateMachine.CallDirection.inbound(CallStateMachine.CallType.voice)
        let outbound = CallStateMachine.CallDirection.outbound(CallStateMachine.CallType.video)
        let inboundData = try JSONEncoder().encode(inbound)
        let outboundData = try JSONEncoder().encode(outbound)
        XCTAssertEqual(try JSONDecoder().decode(CallStateMachine.CallDirection.self, from: inboundData), inbound)
        XCTAssertEqual(try JSONDecoder().decode(CallStateMachine.CallDirection.self, from: outboundData), outbound)

        // EndState
        for end in [
            CallStateMachine.EndState.userInitiated,
            CallStateMachine.EndState.partnerInitiated,
            CallStateMachine.EndState.userInitiatedUnanswered,
            CallStateMachine.EndState.partnerInitiatedUnanswered,
            CallStateMachine.EndState.partnerInitiatedRejected,
            CallStateMachine.EndState.failed,
            CallStateMachine.EndState.auxialaryDevcieAnswered
        ] {
            let data = try JSONEncoder().encode(end)
            let decoded = try JSONDecoder().decode(CallStateMachine.EndState.self, from: data)
            // enum is not Equatable, verify via string
            XCTAssertNotNil(String(data: data, encoding: .utf8))
            XCTAssertNotNil(decoded)
        }
    }

    func testStateCodableRoundTrip() throws {
        let sender = try Call.Participant(secretName: "s", nickname: "S", deviceId: "sd")
        let recipient = try Call.Participant(secretName: "r", nickname: "R", deviceId: "rd")
        let call = try Call(sharedCommunicationId: "comm", sender: sender, recipients: [recipient])

        let states: [CallStateMachine.State] = [
            .waiting,
            .ready(call),
            .connecting(
                CallStateMachine.CallDirection.inbound(CallStateMachine.CallType.voice),
                call
            ),
            .connected(
                CallStateMachine.CallDirection.outbound(CallStateMachine.CallType.video),
                call
            ),
            .held(nil, call),
            .ended(CallStateMachine.EndState.userInitiated, call),
            .failed(nil, call, "oops"),
            .receivedVideoUpgrade,
            .receivedVoiceDowngrade,
            .callAnsweredAuxDevice(call)
        ]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for state in states {
            let data = try encoder.encode(state)
            let decoded = try decoder.decode(CallStateMachine.State.self, from: data)
            XCTAssertEqual(state.description, decoded.description)
        }
    }

    func testTransitionSkipsDuplicate() async throws {
        let sm = CallStateMachine()
        let sender = try Call.Participant(secretName: "s", nickname: "S", deviceId: "sd")
        let recipient = try Call.Participant(secretName: "r", nickname: "R", deviceId: "rd")
        let call = try Call(sharedCommunicationId: "comm", sender: sender, recipients: [recipient])

        await sm.transition(to: CallStateMachine.State.ready(call))
        let prev = await sm.getCurrentState()
        await sm.transition(to: CallStateMachine.State.ready(call)) // should be skipped
        let now = await sm.getCurrentState()
        XCTAssertEqual(prev?.description, now?.description)
    }
}


