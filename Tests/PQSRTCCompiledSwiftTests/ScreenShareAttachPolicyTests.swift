import Foundation
import Testing

@testable import PQSRTC

@Suite(.serialized)
struct ScreenShareAttachPolicyTests {
    @Test("same-presenter activation returns refreshExisting")
    func samePresenterActivationReturnsRefreshExisting() {
        #expect(
            ScreenShareAttachPolicy.duplicateActivationDecision(
                isActive: true,
                samePresenterAlreadyActive: true
            ) == .refreshExisting
        )
        #expect(
            ScreenShareAttachPolicy.duplicateActivationDecision(
                isActive: true,
                samePresenterAlreadyActive: false
            ) == .recreate
        )
    }

    @Test("live sink does not skip when it does not share the mapped wrapper")
    func liveSinkDoesNotSkipWithoutMappedWrapper() {
        #expect(
            ScreenShareAttachPolicy.shouldSkipScreenRendererAttach(
                hasActiveSink: true,
                attachedTrackIsLive: true,
                sharesMappedWrapper: false,
                layoutNeedsReconcile: false
            ) == false
        )
    }

    @Test("layout reconcile required means do not skip")
    func layoutReconcileRequiredDoesNotSkip() {
        #expect(
            ScreenShareAttachPolicy.shouldSkipScreenRendererAttach(
                hasActiveSink: true,
                attachedTrackIsLive: true,
                sharesMappedWrapper: true,
                layoutNeedsReconcile: true
            ) == false
        )
    }

    @Test("wrapper A to wrapper B with the same trackId is a rebind")
    func sameTrackIdDifferentWrapperIsRebind() {
        #expect(
            ScreenShareAttachPolicy.shouldRebindScreenWrapper(
                storedTrackId: "screen_echo_1",
                liveTrackId: "screen_echo_1",
                platformTracksIdentical: false
            )
        )
        #expect(
            ScreenShareAttachPolicy.shouldRebindScreenWrapper(
                storedTrackId: "screen_echo_1",
                liveTrackId: "screen_echo_1",
                platformTracksIdentical: true
            ) == false
        )
    }

    @Test("healthy current wrapper skip is idempotent")
    func healthyCurrentWrapperSkipIsIdempotent() {
        #expect(
            ScreenShareAttachPolicy.shouldSkipScreenRendererAttach(
                hasActiveSink: true,
                attachedTrackIsLive: true,
                sharesMappedWrapper: true,
                layoutNeedsReconcile: false
            )
        )
    }

    @Test("Android duplicate activation source enters refresh policy")
    func androidDuplicateActivationSourceEntersRefreshPolicy() throws {
        let source = try Self.controllerSource()
        let body = try Self.sourceBody(of: "handleRemoteScreenTrackEvent", in: source)
        #expect(!body.contains("Ignoring duplicate remote screen-share activation"))
        #expect(body.contains("ScreenShareAttachPolicy.duplicateActivationDecision"))
        #expect(body.contains(".refreshExisting"))
    }

    @Test("setScreenView skip uses mapped-wrapper attach policy")
    func setScreenViewSkipUsesMappedWrapperPolicy() throws {
        let source = try Self.controllerSource()
        let body = try Self.sourceBody(of: "setScreenView", in: source)
        #expect(body.contains("ScreenShareAttachPolicy.shouldSkipScreenRendererAttach"))
        #expect(body.contains("sharesMappedWrapper") || body.contains("attachedTrackSharesRendererSink"))
    }

    private static func controllerSource() throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/PQSRTC/Views/Android/AndroidVideoCallController.swift"
            ),
            encoding: .utf8
        )
    }

    private static func sourceBody(of functionName: String, in source: String) throws -> String {
        let marker = "func \(functionName)"
        guard let start = source.range(of: marker) else {
            throw SourceGuardError.missingFunction(functionName)
        }
        let suffix = source[start.lowerBound...]
        guard let openingBrace = suffix.firstIndex(of: "{") else {
            throw SourceGuardError.missingFunction(functionName)
        }
        var depth = 0
        for index in suffix.indices[openingBrace...] {
            switch suffix[index] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(suffix[...index])
                }
            default:
                break
            }
        }
        throw SourceGuardError.missingFunction(functionName)
    }

    private enum SourceGuardError: Error {
        case missingFunction(String)
    }
}
