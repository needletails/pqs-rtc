import Foundation
import Testing

@testable import PQSRTC

/// libwebrtc (webrtc-sdk 144) reports `createOffer`/`createAnswer` failures through
/// `SdpObserver.onCreateFailure`: "CreateOffer called when PeerConnection is closed.",
/// "CreateOffer/CreateAnswer failed because the session was shut down" (hangup, relay reset),
/// or a wrong signaling state. If the Android client drops that callback, the awaiting
/// `createOffer`/`createAnswer` never resumes and, for SFU offers, every later
/// TaskProcessor signalling job stalls behind it. `AndroidRTCClient.swift` is `#if SKIP`
/// (transpiled to Kotlin), so this pins the source shape.
@Suite(.serialized)
struct AndroidCreateSdpFailureResumesTests {
    @Test("create-SDP observer forwards onCreateFailure to its caller")
    func createSdpObserverForwardsCreateFailure() throws {
        let client = try source("Sources/PQSRTC/Android/AndroidRTCClient.swift")
        let observerStart = try #require(client.range(of: "class RTCOnCreateSdpObserver"))
        let observer = String(client[observerStart.lowerBound...])
        let failure = try SourceContract.sourceBody(of: "onCreateFailure", in: observer)
        let openingBrace = try #require(failure.firstIndex(of: "{"))
        let inner = failure[failure.index(after: openingBrace)...].dropLast()
        #expect(!inner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(inner.contains("callback("))
    }

    @Test("createOffer and createAnswer resume their continuation on failure")
    func createOfferAndAnswerResumeOnFailure() throws {
        let client = try source("Sources/PQSRTC/Android/AndroidRTCClient.swift")
        for name in ["createOffer", "createAnswer"] {
            let body = try SourceContract.sourceBody(
                of: "\(name)(constraints: RTCMediaConstraints) async",
                in: client
            )
            #expect(
                body.contains("resume(with:") || body.contains("resume(throwing:"),
                "\(name) resumes only on success"
            )
        }
    }

    /// In Skip-transpiled Kotlin, `Result` is ambiguous between Skip's `Result<Success, Failure>`
    /// and `kotlin.Result<T>`, so `.success`/`.failure` and `resume(with:)` fail `compileDebugKotlin`.
    @Test("transpiled Android client does not use Swift Result")
    func transpiledClientAvoidsSwiftResult() throws {
        let client = try source("Sources/PQSRTC/Android/AndroidRTCClient.swift")
        #expect(!client.contains("Result<"))
        #expect(!client.contains("resume(with:"))
    }

    private func source(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
