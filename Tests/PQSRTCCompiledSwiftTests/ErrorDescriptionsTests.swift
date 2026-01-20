import Testing

@testable import PQSRTC

@Suite(.serialized)
struct ErrorDescriptionsTests {
    @Test
    func connectionErrorsHaveHumanReadableDescriptions() {
        #expect(ConnectionErrors.rejected.errorDescription == "Call was rejected")
        #expect(ConnectionErrors.unanswered.errorDescription == "Call was unanswered")
        #expect(ConnectionErrors.connectionNotFound.errorDescription == "Connection not found")
    }

    @Test
    func sdpHandlerErrorDescriptions() {
        #expect(SDPHandlerError.invalidSDPFormat("x").errorDescription == "Invalid SDP format: x")
        #expect(SDPHandlerError.unsupportedMediaType("y").errorDescription == "Unsupported media type: y")
        #expect(SDPHandlerError.sdpGenerationFailed("z").errorDescription == "SDP generation failed: z")
        #expect(SDPHandlerError.sdpParsingFailed("p").errorDescription == "SDP parsing failed: p")
        #expect(SDPHandlerError.invalidConstraints("c").errorDescription == "Invalid constraints: c")
    }
}
