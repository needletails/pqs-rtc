import Foundation
import Testing
@testable import PQSRTC

@Suite("Outbound signaling transport retry")
struct OutboundSignalingTransportRetryTests {
    @Test("answer survives transient transport failures while retries remain")
    func answerRetriesTransientTransport() {
        #expect(TaskProcessor.shouldRetryOutboundTransportSend(
            flag: .answer,
            isWriterNotReady: false,
            isTransientTransportFailure: true,
            attempt: 0))
        #expect(TaskProcessor.shouldRetryOutboundTransportSend(
            flag: .answer,
            isWriterNotReady: false,
            isTransientTransportFailure: true,
            attempt: 23))
        #expect(!TaskProcessor.shouldRetryOutboundTransportSend(
            flag: .answer,
            isWriterNotReady: false,
            isTransientTransportFailure: true,
            attempt: 24))
    }

    @Test("candidate does not retry non-writer transport failures")
    func candidateDoesNotRetryTransientTransport() {
        #expect(!TaskProcessor.shouldRetryOutboundTransportSend(
            flag: .candidate,
            isWriterNotReady: false,
            isTransientTransportFailure: true,
            attempt: 0))
        #expect(TaskProcessor.shouldRetryOutboundTransportSend(
            flag: .candidate,
            isWriterNotReady: true,
            isTransientTransportFailure: false,
            attempt: 0))
    }

    @Test("offer retries writer-not-ready like answer")
    func offerRetriesWriterNotReady() {
        #expect(TaskProcessor.shouldRetryOutboundTransportSend(
            flag: .offer,
            isWriterNotReady: true,
            isTransientTransportFailure: false,
            attempt: 0))
    }

    private struct StubError: Error, LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    @Test("production error signatures classify as transient transport failures")
    func productionSignaturesAreTransient() {
        // Exact string from PARTICIPANT_APPLE_LOGS: the renegotiation answer that was
        // dropped when the SFU socket recycled mid group call.
        #expect(TaskProcessor.isTransientTransportSendError(
            StubError(text: "I/O on closed channel")))
        #expect(TaskProcessor.isTransientTransportSendError(
            StubError(text: "ioOnClosedChannel")))
        #expect(TaskProcessor.isTransientTransportSendError(
            StubError(text: "NIOAsyncWriterError.alreadyFinished")))
        #expect(TaskProcessor.isTransientTransportSendError(
            StubError(text: "writerNotSet")))
        #expect(TaskProcessor.isTransientTransportSendError(
            StubError(text: "Connection reset by peer")))
    }

    @Test("genuine failures are not classified transient")
    func genuineFailuresAreTerminal() {
        #expect(!TaskProcessor.isTransientTransportSendError(
            StubError(text: "Remote props not found for roomId=x")))
        #expect(!TaskProcessor.isTransientTransportSendError(
            StubError(text: "invalid configuration")))
        #expect(!TaskProcessor.isTransientTransportSendError(CancellationError()))
    }
}
