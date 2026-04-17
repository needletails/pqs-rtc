#if canImport(WebRTC)
import Foundation
import Testing

@testable import PQSRTC

@Suite(.serialized)
struct RTCSessionDeferredReceiveShutdownTests {
    @Test
    func shutdownClearsPendingAppleDeferredReceiveFrameKeyContext() async throws {
        let session = await RTCSession(
            iceServers: ["stun:stun.l.google.com:19302"],
            username: "",
            password: "",
            enableEncryption: true,
            delegate: nil
        )
        let id = UUID().uuidString
        await session.testing_seedPendingAppleDeferredReceiveFrameKeyForTests(normalizedConnectionId: id)
        #expect(await session.testing_pendingAppleDeferredReceiveFrameKeyEntryCount() == 1)

        await session.shutdown(with: nil)

        #expect(await session.testing_pendingAppleDeferredReceiveFrameKeyEntryCount() == 0)
    }
}
#endif
