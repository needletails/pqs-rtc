//
//  SessionDescriptionTests.swift
//  needle-tail-rtc
//
//  Created by GPT-5 Assistant on 10/6/25.
//

import Foundation
import SkipTest
@preconcurrency import WebRTC
@testable import NeedleTailRTC

final class SessionDescriptionTests: XCTestCase {
    func testSdpTypeRoundTripAllCases() throws {
        for type in SdpType.allCases {
            XCTAssertFalse(type.rawValue.isEmpty)
            XCTAssertEqual(type.description, type.rawValue)
        }
    }

    func testSessionDescriptionInitValidation() throws {
        #if !os(Android)
        // Only validate constructor bridging when WebRTC is available
        let valid = try SessionDescription(fromRTC: RTCSessionDescription(type: .offer, sdp: "v=0\r\n"))
        XCTAssertTrue(valid.isOffer)
        XCTAssertEqual(valid.type, SdpType.offer)

        XCTAssertThrowsError(try SessionDescription(fromRTC: RTCSessionDescription(type: .offer, sdp: "   "))) { error in
            if let err = error as? SessionDescriptionError, case .invalidSDP = err { /* ok */ } else { return XCTFail("Expected invalidSDP") }
        }
        #endif
    }

    func testSessionDescriptionHelpers() {
        #if !os(Android)
        let rtc = RTCSessionDescription(type: .answer, sdp: "v=0\r\n")
        let desc = try! SessionDescription(fromRTC: rtc)
        XCTAssertTrue(desc.isAnswer)
        XCTAssertFalse(desc.isOffer)
        XCTAssertFalse(desc.isRollback)
        XCTAssertFalse(desc.isPrAnswer)
        XCTAssertTrue(desc.description.contains("sdpLength"))
        #endif
    }
}


