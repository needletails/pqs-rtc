//
//  CallTests.swift
//  needle-tail-rtc
//
//  Created by GPT-5 Assistant on 10/6/25.
//

import Foundation
import SkipTest
@testable import NeedleTailRTC

final class CallTests: XCTestCase {
    func testParticipantInitValidation() throws {
        // Valid participant
        let p = try Call.Participant(secretName: "alice", nickname: "Alice", deviceId: "dev1")
        XCTAssertEqual(p.secretName, "alice")
        XCTAssertEqual(p.nickname, "Alice")
        XCTAssertEqual(p.deviceId, "dev1")

        // Invalid secretName
        XCTAssertThrowsError(try Call.Participant(secretName: " ", nickname: "n", deviceId: "d")) { error in
            if let err = error as? CallError, case .invalidParticipant = err { /* ok */ } else { return XCTFail("Expected invalidParticipant") }
        }

        // Invalid nickname
        XCTAssertThrowsError(try Call.Participant(secretName: "s", nickname: "", deviceId: "d")) { error in
            if let err = error as? CallError, case .invalidParticipant = err { /* ok */ } else { return XCTFail("Expected invalidParticipant") }
        }
    }

    func testCallInitValidation() throws {
        let sender = try Call.Participant(secretName: "s", nickname: "S", deviceId: "sd")
        let recipient = try Call.Participant(secretName: "r", nickname: "R", deviceId: "rd")

        // Valid call
        let call = try Call(
            sharedCommunicationId: "comm",
            sender: sender,
            recipients: [recipient],
            supportsVideo: true,
            isActive: true
        )
        XCTAssertEqual(call.sharedCommunicationId, "comm")
        XCTAssertTrue(call.supportsVideo)
        XCTAssertTrue(call.isActive)

        // Empty communication id
        XCTAssertThrowsError(try Call(
            sharedCommunicationId: " ",
            sender: sender,
            recipients: [recipient]
        )) { error in
            if let err = error as? CallError, case .invalidMetadata = err { /* ok */ } else { return XCTFail("Expected invalidMetadata") }
        }

        // Empty recipients
        XCTAssertThrowsError(try Call(
            sharedCommunicationId: "comm",
            sender: sender,
            recipients: []
        )) { error in
            if let err = error as? CallError, case .invalidMetadata = err { /* ok */ } else { return XCTFail("Expected invalidMetadata") }
        }
    }

    func testEndCallUpdatesFlagsAndDuration() throws {
        let sender = try Call.Participant(secretName: "s", nickname: "S", deviceId: "sd")
        let recipient = try Call.Participant(secretName: "r", nickname: "R", deviceId: "rd")

        var call = try Call(
            sharedCommunicationId: "comm",
            sender: sender,
            recipients: [recipient],
            createdAt: Date(timeIntervalSince1970: 1_000),
            isActive: true
        )

        XCTAssertFalse(call.hasEnded)
        XCTAssertFalse(call.isTerminal) // active true, not ended

        call.endCall(endState: Call.EndState.unanswered)
        XCTAssertTrue(call.hasEnded)
        XCTAssertTrue(call.isTerminal)
        XCTAssertEqual(call.unanswered, true)
        XCTAssertNotNil(call.endedAt)
        if let endedAt = call.endedAt {
            XCTAssertGreaterThanOrEqual(endedAt, call.createdAt)
            XCTAssertNotNil(call.duration)
        }
    }
}


