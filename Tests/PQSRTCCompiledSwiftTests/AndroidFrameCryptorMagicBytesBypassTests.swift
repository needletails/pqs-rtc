import Foundation
import Testing

@testable import PQSRTC

/// The bundled webrtc-sdk 144 receive transformer passes any frame whose tail equals the key
/// provider's `uncryptedMagicBytes` to the decoder without decrypting it (the check is skipped
/// only when the bytes are empty). With a non-empty value a compromised SFU can inject media
/// under any tile without a key, and nothing in PQSRTC sends such frames. `null` is not an
/// option: the JNI wrapper reads the array with `GetByteArrayElements` and no null check, which
/// aborts the process. `AndroidRTCClient.swift` is `#if SKIP` (transpiled to Kotlin), so this
/// pins the source shape.
@Suite(.serialized)
struct AndroidFrameCryptorMagicBytesBypassTests {
    @Test("Android key providers disable the uncrypted magic-bytes bypass")
    func androidKeyProvidersPassEmptyUncryptedMagicBytes() throws {
        let client = try source("Sources/PQSRTC/Android/AndroidRTCClient.swift")
        #expect(!client.contains("PQSRTCMagicBytes"))
        for name in ["ensureSharedKeyProvider(ratchetSalt:", "ensureKeyProvider(sharedKeyMode:"] {
            let body = try SourceContract.sourceBody(of: name, in: client)
            let declaration = try #require(
                body.components(separatedBy: "\n").first { $0.contains("val uncryptedMagicBytes") },
                "\(name) declares no uncryptedMagicBytes"
            )
            let value = try #require(declaration.components(separatedBy: "=").last)
                .trimmingCharacters(in: .whitespaces)
            #expect(value == "kotlin.ByteArray(0)", "\(name) passes \(value)")
            #expect(body.contains("uncryptedMagicBytes,"))
        }
    }

    private func source(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
