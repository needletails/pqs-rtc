import Foundation
import Testing

@testable import PQSRTC

@Suite(.serialized)
struct AndroidVideoSenderEncodingSourceTests {
    @Test("video sender encoding updates use stable sender wrappers")
    func setVideoSenderEncodingsDoesNotUsePcSenders() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/PQSRTC/Android/AndroidRTCClient.swift"
            ),
            encoding: .utf8
        )
        let body = try sourceBody(of: "setVideoSenderEncodings", in: source)
        #expect(!body.contains("pc.senders"))
        #expect(!body.contains("getSenders()"))
        #expect(body.contains("AndroidWebRTCTrackResolver.stableSenders"))
    }

    private func sourceBody(of functionName: String, in source: String) throws -> String {
        let marker = "func \(functionName)"
        guard let start = source.range(of: marker),
              let openingBrace = source[start.lowerBound...].firstIndex(of: "{") else {
            throw SourceGuardError.missingFunction
        }
        let suffix = source[start.lowerBound...]
        var depth = 0
        for index in suffix.indices[openingBrace...] {
            switch suffix[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(suffix[...index]) }
            default: break
            }
        }
        throw SourceGuardError.missingFunction
    }

    private enum SourceGuardError: Error {
        case missingFunction
    }
}
