import Foundation
import Testing

@testable import PQSRTC

/// Android keeps one `PeerConnection` slot on the shared `AndroidRTCClient`. If a call's teardown
/// is still pending (for example `.failed` awaits `didEnd` before `finishEndConnection`) when the
/// next call creates its PeerConnection, `initializeFactory` replaced the old one without closing
/// it, and every observer reported into whatever delegate was current, so the old PeerConnection's
/// ICE/CLOSED transitions arrived under the new connection id and ended it. The old call's
/// `cleanup(connection:)` then ran `resetPeerConnectionForRetry()`, which always reset the current
/// (new) PeerConnection. `AndroidRTCClient.swift` is `#if SKIP`, so this pins the source shape.
@Suite(.serialized)
struct AndroidStaleTeardownTests {
    @Test("Android initializeFactory closes the PeerConnection it replaces")
    func initializeFactoryClosesReplacedPeerConnection() throws {
        let client = try source("Sources/PQSRTC/Android/AndroidRTCClient.swift")
        let body = try SourceContract.sourceBody(of: "initializeFactory(", in: client)
        let take = try #require(
            body.range(of: "let replacedPeerConnection = peerConnection?.platformPeerConnection"),
            "the replaced PeerConnection is dropped without being closed"
        )
        let section = try #require(body[take.upperBound...].range(of: "lock.unlock()"))
        let taken = body[take.upperBound..<section.lowerBound]
        #expect(taken.contains("peerConnection = nil"))
        #expect(taken.contains("observer = nil"), "its CLOSED callbacks would reach the new connection's delegate")

        // Retired before the new one is created, and outside the do/catch that marks the client
        // permanently failed.
        let create = try #require(body.range(of: "do {\n            let pc = try createPeerConnection("))
        let retired = body[section.upperBound..<create.lowerBound]
        let retire = try #require(retired.range(of: "markPeerConnectionRetired(peerConnection: replacedPeerConnection)"))
        let close = try #require(retired.range(of: "replacedPeerConnection?.close()"))
        let dispose = try #require(retired.range(of: "replacedPeerConnection?.dispose()"))
        #expect(retire.lowerBound < close.lowerBound)
        #expect(close.lowerBound < dispose.lowerBound)

        // Its FrameCryptors go with it. The sender attach keeps any cryptor it already holds, so
        // ones left bound to the old senders would leave the new call's senders unencrypted.
        let cryptors = try #require(
            retired.range(of: "frameCryptorSupport.disposeAll()"),
            "the new call's sender attach keeps the replaced PeerConnection's cryptors"
        )
        #expect(cryptors.lowerBound < close.lowerBound)
    }

    @Test("Android peer observer reports only while it observes the current PeerConnection")
    func peerObserverReportsOnlyWhileCurrent() throws {
        let client = try source("Sources/PQSRTC/Android/AndroidRTCClient.swift")
        let start = try #require(client.range(of: "class RTCClientPeerObserver("))
        let end = try #require(client[start.upperBound...].range(of: "/// Android WebRTC `SdpObserver`"))
        let observer = client[start.lowerBound..<end.lowerBound]
        let reports = observer.split(separator: "\n").filter { $0.contains("client.triggerRTCEvent(") }
        #expect(reports.count >= 15)
        for line in reports {
            #expect(line.hasSuffix(", this)"), "observer event not tied to its PeerConnection: \(line)")
        }
        #expect(
            !observer.contains("client.retireCurrentNativePeerConnection()"),
            "a replaced PeerConnection's CLOSED retires the new current one"
        )

        let trigger = try SourceContract.sourceBody(of: "triggerRTCEvent(", in: client)
        #expect(trigger.contains("guard !isClosed, observer === source else"))
    }

    @Test("Android reset leaves a newer PeerConnection alone when given the old one")
    func resetForStalePeerConnectionIsNoOp() throws {
        let client = try source("Sources/PQSRTC/Android/AndroidRTCClient.swift")
        #expect(client.contains("public func resetPeerConnectionForRetry(_ target: RTCPeerConnection? = nil)"))
        let body = try SourceContract.sourceBody(of: "resetPeerConnectionForRetry(", in: client)
        let guardRange = try #require(
            body.range(of: "target == nil || target?.platformPeerConnection === peerConnection?.platformPeerConnection"),
            "reset always tears down the current PeerConnection"
        )
        let firstTeardown = try #require(body.range(of: "videoCapturerToStop = videoCapturer"))
        #expect(guardRange.lowerBound < firstTeardown.lowerBound)
    }

    @Test("Android call teardown resets and retires only the call's own PeerConnection")
    func callTeardownTargetsItsOwnPeerConnection() throws {
        let peer = try source("Sources/PQSRTC/RTCSession+PeerConnection.swift")
        // An untargeted reset or retire hits whatever PeerConnection is current: the next call's.
        #expect(!peer.contains("resetPeerConnectionForRetry()"), "a late call teardown resets the next call's PeerConnection")
        #expect(!peer.contains("retireCurrentNativePeerConnection()"), "a late media release retires the next call's PeerConnection")

        let cleanup = try SourceContract.sourceBody(of: "cleanup(connection: RTCConnection)", in: peer)
        #expect(cleanup.contains("resetPeerConnectionForRetry(connection.peerConnection)"))

        let release = try SourceContract.sourceBody(of: "releaseLocalMediaResourcesForCallEnding(connectionId", in: peer)
        #expect(release.contains("retireCurrentNativePeerConnection(connection.peerConnection)"))

        // Shutdown's own reset runs after finishEndConnection removed the connection, so it
        // takes the call's PeerConnection from before that.
        let shutdown = try SourceContract.sourceBody(of: "shutdown(\n        with call: Call?", in: peer)
        let own = try #require(shutdown.range(of: "findConnection(with: call.sharedCommunicationId)?.peerConnection"))
        let finish = try #require(shutdown.range(of: "await finishEndConnection(currentCall: call"))
        #expect(own.lowerBound < finish.lowerBound)
        #expect(shutdown.contains("resetPeerConnectionForRetry(ownPeerConnection)"))

        // The retire leaves a newer PeerConnection alone, like the reset.
        let client = try source("Sources/PQSRTC/Android/AndroidRTCClient.swift")
        #expect(client.contains("public func retireCurrentNativePeerConnection(_ target: RTCPeerConnection? = nil)"))
        let retire = try SourceContract.sourceBody(of: "retireCurrentNativePeerConnection(", in: client)
        #expect(retire.contains("target == nil || target?.platformPeerConnection === pc"))
    }

    private func source(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
