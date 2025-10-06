//
//  IceCandidateTests.swift
//  needle-tail-rtc
//
//  Created by GPT-5 Assistant on 10/6/25.
//

import Foundation
import SkipTest
@preconcurrency import WebRTC
@testable import NeedleTailRTC

final class IceCandidateTests: XCTestCase {
    func testValidationErrors() throws {
        #if !os(Android)
        XCTAssertThrowsError(try IceCandidate(from: RTCIceCandidate(sdp: " ", sdpMLineIndex: 0, sdpMid: "0"), id: 1)) { error in
            if let err = error as? IceCandidateError, case .invalidSDP = err { /* ok */ } else { return XCTFail("Expected invalidSDP") }
        }
        XCTAssertThrowsError(try IceCandidate(from: RTCIceCandidate(sdp: "candidate:...", sdpMLineIndex: -1, sdpMid: "0"), id: 1)) { error in
            if let err = error as? IceCandidateError, case .invalidMLineIndex = err { /* ok */ } else { return XCTFail("Expected invalidMLineIndex") }
        }
        XCTAssertThrowsError(try IceCandidate(from: RTCIceCandidate(sdp: "candidate:...", sdpMLineIndex: 0, sdpMid: "0"), id: -1)) { error in
            if let err = error as? IceCandidateError, case .invalidID = err { /* ok */ } else { return XCTFail("Expected invalidID") }
        }
        #endif
    }

    func testHelpers() throws {
        #if !os(Android)
        let cand = try IceCandidate(from: RTCIceCandidate(sdp: "candidate: 1 1 UDP 2122252543 192.168.1.2 56143 typ host", sdpMLineIndex: 0, sdpMid: "0"), id: 42)
        XCTAssertEqual(cand.id, 42)
        XCTAssertTrue(cand.isLocal)
        XCTAssertFalse(cand.isRelay)
        XCTAssertEqual(cand.candidateType, "host")
        XCTAssertTrue(cand.description.contains("id: 42"))

        let relay = try IceCandidate(from: RTCIceCandidate(sdp: "candidate: 2 1 UDP 1234 1.2.3.4 9999 typ relay", sdpMLineIndex: 0, sdpMid: nil), id: 9)
        XCTAssertTrue(relay.isRelay)
        XCTAssertEqual(relay.candidateType, "relay")

        // Round-trip to RTCIceCandidate
        let rtc = cand.rtcIceCandidate
        XCTAssertEqual(rtc.sdp, cand.sdp)
        XCTAssertEqual(rtc.sdpMLineIndex, cand.sdpMLineIndex)
        #endif
    }
}


