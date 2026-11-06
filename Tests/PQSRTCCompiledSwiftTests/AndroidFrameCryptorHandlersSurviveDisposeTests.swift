import Foundation
import Testing

@testable import PQSRTC

/// `RTCSession` installs the Android FrameCryptor video-ready and state handlers once, at init.
/// `AndroidFrameCryptorSupport.disposeAll()` runs on every key-provider change (the first
/// provider creation included, through `setKeyProvider`), on `clearKeyProvider`, ICE retry and
/// close. When it nulled the handlers, `handleAndroidVideoReceiverFrameCryptorReady` and the
/// decrypt/missing-key `E2EEStateEvent`s never fired on Android. `AndroidRTCNativeSupport.kt` is
/// Kotlin and `AndroidRTCClient.swift` is `#if SKIP`, so this pins the source shape.
@Suite(.serialized)
struct AndroidFrameCryptorHandlersSurviveDisposeTests {
    @Test("Android cryptor teardown keeps the session-lifetime handlers")
    func cryptorTeardownKeepsSessionLifetimeHandlers() throws {
        let session = try source("Sources/PQSRTC/RTCSession.swift")
        #expect(session.contains("installAndroidVideoReceiverFrameCryptorReadyHandler()"))
        #expect(session.contains("installAndroidFrameCryptorFailureHandler()"))

        let client = try source("Sources/PQSRTC/Android/AndroidRTCClient.swift")
        #expect(client.contains("frameCryptorSupport.setKeyProvider(keyProvider)"))

        let native = try source("Sources/PQSRTC/Skip/AndroidRTCNativeSupport.kt")
        let setKeyProvider = try kotlinBody(of: "setKeyProvider", in: native)
        #expect(setKeyProvider.contains("disposeAll()"))

        let disposeAll = try kotlinBody(of: "disposeAll", in: native)
        for handler in ["videoReceiverFrameCryptorReadyHandler", "frameCryptorStateHandler"] {
            #expect(lines(of: disposeAll, containing: handler) == [], "disposeAll() wipes \(handler)")
            #expect(lines(of: native, containing: "\(handler) = null") == [], "Kotlin wipes \(handler)")
            #expect(lines(of: client, containing: "frameCryptorSupport.\(handler) = nil") == [])
        }
    }

    private func lines(of source: String, containing text: String) -> [String] {
        source.components(separatedBy: "\n")
            .filter { $0.contains(text) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func kotlinBody(of name: String, in source: String) throws -> String {
        guard let header = source.range(of: "fun \(name)("),
              let openBrace = source[header.lowerBound...].firstIndex(of: "{") else {
            throw SourceContract.Error.missingFunction(name)
        }
        let fromHeader = source[header.lowerBound...]
        var depth = 0
        for index in fromHeader.indices[openBrace...] {
            if fromHeader[index] == "{" { depth += 1 }
            if fromHeader[index] == "}" {
                depth -= 1
                if depth == 0 { return String(fromHeader[...index]) }
            }
        }
        throw SourceContract.Error.missingFunction(name)
    }

    private func source(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
