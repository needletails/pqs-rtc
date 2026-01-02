import Foundation
import Testing
#if canImport(WebRTC)
@preconcurrency import WebRTC
@testable import PQSRTC

@Suite
struct SessionDescriptionTests {
    @Test
    func sdpTypeRoundTripAllCases() {
        for type in SdpType.allCases {
            #expect(!type.rawValue.isEmpty)
            #expect(type.description == type.rawValue)
        }
    }

    @Test
    func sessionDescriptionInitValidation() throws {
        let valid = try SessionDescription(fromRTC: RTCSessionDescription(type: .offer, sdp: "v=0\r\n"))
        #expect(valid.isOffer == true)
        #expect(valid.type == .offer)

        #expect(throws: Error.self) {
            _ = try SessionDescription(fromRTC: RTCSessionDescription(type: .offer, sdp: "   "))
        }
    }

    @Test
    func sessionDescriptionHelpers() throws {
        let rtc = RTCSessionDescription(type: .answer, sdp: "v=0\r\n")
        let desc = try SessionDescription(fromRTC: rtc)

        #expect(desc.isAnswer == true)
        #expect(desc.isOffer == false)
        #expect(desc.isRollback == false)
        #expect(desc.isPrAnswer == false)
        #expect(desc.description.contains("sdpLength"))
    }
}
#endif
