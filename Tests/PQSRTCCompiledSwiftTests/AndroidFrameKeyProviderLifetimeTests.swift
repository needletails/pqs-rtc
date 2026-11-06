import Foundation
import Testing

@testable import PQSRTC

/// Android sender FrameCryptors need a key provider. The session binds them at track-add only
/// when `isFrameKeyProviderReady()`, and a group key install never binds them afterwards, so a
/// call that starts with no provider sends camera and microphone RTP unencrypted until a later
/// attach. Apple always has a provider while E2EE is on (created at RTCSession init and created
/// again by the next ensure after hangup), so its sender cryptors bind at track-add and drop
/// frames until a key arrives. On Android a session's first call started with no provider,
/// hangup used to leave none, and a provider could only be created by installing a key. `AndroidRTCClient.swift` is `#if SKIP`
/// (transpiled to Kotlin), so this pins the source shape.
@Suite(.serialized)
struct AndroidFrameKeyProviderLifetimeTests {
    @Test("hangup reset leaves a fresh key provider for the next call")
    func hangupResetLeavesFreshKeyProvider() throws {
        let client = try source("Sources/PQSRTC/Android/AndroidRTCClient.swift")
        let reset = try SourceContract.sourceBody(of: "resetFrameKeyProviderForHangup", in: client)

        // The old key ring is still dropped...
        #expect(reset.contains("frameCryptorSupport.clearKeyProvider()"))
        // ...and replaced with an empty provider of the same mode and salt. ensureKeyProvider
        // takes `lock`, so the replacement must run after the reset has released it.
        let recreate = try #require(
            reset.range(of: "ensureKeyProvider(sharedKeyMode:"),
            "hangup reset leaves the next call with no key provider"
        )
        let lastUnlock = try #require(reset.range(of: "lock.unlock()", options: .backwards))
        #expect(lastUnlock.lowerBound < recreate.lowerBound)
        #expect(!reset.contains("defer { lock.unlock() }"))
        #expect(reset.contains("keyProviderIsSharedKeyMode"))
        #expect(reset.contains("keyProviderRatchetSalt"))

        // Both creation paths record the salt the replacement needs.
        for name in ["ensureSharedKeyProvider(ratchetSalt:", "ensureKeyProvider(sharedKeyMode:"] {
            let body = try SourceContract.sourceBody(of: name, in: client)
            #expect(body.contains("this@AndroidRTCClient.keyProviderRatchetSalt = ratchetSalt"), "\(name) does not record its salt")
        }
    }

    @Test("the session creates the key provider at init, before its first call adds senders")
    func sessionCreatesKeyProviderAtInit() throws {
        let session = try source("Sources/PQSRTC/RTCSession.swift")
        let start = try #require(session.range(of: "    public init(\n        iceServers: [String],"))
        let end = try #require(session[start.upperBound...].range(of: "func ensureFrameKeyProviderIfNeeded()"))
        let initBody = session[start.lowerBound..<end.lowerBound]

        // Same mode and salt as Apple's provider, and only when E2EE is on.
        let ensure = try #require(
            initBody.range(of: "rtcClient.ensureKeyProvider(sharedKeyMode: frameEncryptionKeyMode == .shared, ratchetSalt: ratchetSalt)"),
            "the first Android call adds senders with no key provider and sends clear media"
        )
        let before = initBody[..<ensure.lowerBound]
        let block = try #require(before.range(of: "#if ", options: .backwards))
        let androidBlock = before[block.lowerBound...]
        #expect(androidBlock.hasPrefix("#if os(Android)"))
        #expect(!androidBlock.contains("#endif"))
        #expect(androidBlock.contains("if enableEncryption {"))
    }

    private func source(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
