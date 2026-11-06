import Foundation
import Testing

@testable import PQSRTC

/// With frame E2EE on, remote audio is ciphertext until its receiver FrameCryptor binds, and
/// `didAddReceiver` may defer that attach on Android (1:1 SFU before the receive key, group audio
/// owned by the SDP reconcile, group before a stable participant id). The only Android hold sat
/// inside `attachAudioReceiverCryptor`, so the track played noise for the whole deferral.
/// `AndroidRTCClient.swift` is `#if SKIP` and `AndroidRTCNativeSupport.kt` is Kotlin, so this pins
/// the source shape.
@Suite(.serialized)
struct AndroidRemoteAudioHeldUntilCryptorTests {
    @Test("Android remote audio is held from onTrack until its receiver cryptor binds")
    func remoteAudioHeldFromArrivalUntilCryptorBinds() throws {
        let client = try source("Sources/PQSRTC/Android/AndroidRTCClient.swift")
        let observer = client.components(separatedBy: "\n")
            .compactMap { line -> String? in
                guard let range = line.range(of: "// SKIP INSERT:") else { return nil }
                return String(line[range.upperBound...])
            }
            .joined(separator: "\n")
        let onTrack = try kotlinBody(of: "onTrack", in: observer)
        let audioBranch = try #require(
            onTrack.range(of: "is org.webrtc.AudioTrack ->").map { String(onTrack[$0.upperBound...]) }
        )
        let hold = try #require(
            audioBranch.range(of: "client.holdRemoteAudioUntilReceiverCryptorAttached(transceiver.receiver)"),
            "onTrack emits remote audio without holding it until its cryptor binds"
        )
        let emit = try #require(audioBranch.range(of: "ClientPCEvent.audioTrack("))
        #expect(hold.lowerBound < emit.lowerBound, "hold must precede the didAddReceiver event")

        let native = try source("Sources/PQSRTC/Skip/AndroidRTCNativeSupport.kt")
        // onTrack runs on the WebRTC signaling thread, and attach holds this monitor while it
        // blocks on that thread (setEnabled, getReceivers), so the hold is posted to main.
        let entry = try kotlinBody(of: "holdRemoteAudioUntilCryptorAttached", in: native)
        #expect(entry.contains("Handler(Looper.getMainLooper()).post"))
        let onMain = try kotlinBody(of: "holdUnboundRemoteAudioOnMain", in: native)
        #expect(native.contains("@Synchronized\n    private fun holdUnboundRemoteAudioOnMain("))
        #expect(onMain.contains("keyProvider == null"), "plaintext sessions must never hold")
        #expect(onMain.contains("audioReceiverTrackIdsByParticipantId.containsValue(trackId)"),
                "a track whose cryptor is already bound must stay audible")
        #expect(onMain.contains("holdAndroidRemoteAudioReceiverTrack(receiver)"))

        let attach = try kotlinBody(of: "attachAudioReceiverCryptor", in: native)
        let stored = try #require(attach.range(of: "audioReceiverTrackIdsByParticipantId[participant] = trackId"))
        #expect(attach[stored.upperBound...].contains("enableAndroidRemoteAudioReceiverTrack(receiver)"))
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
