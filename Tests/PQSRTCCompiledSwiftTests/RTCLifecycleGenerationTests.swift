import Foundation
import Testing

@testable import PQSRTC

@Suite(.serialized)
struct RTCLifecycleGenerationTests {
    actor Transport: RTCTransportEvents {
        func sendCiphertext(recipient: String, connectionId: String, ciphertext: Data, call: Call) async throws {}
        func sendSfuMessage(_ packet: RatchetMessagePacket, call: Call) async throws {}
        func sendStartCall(_ call: Call) async throws {}
        func sendCallAnswered(_ call: Call) async throws {}
        func sendCallAnsweredAuxDevice(_ call: Call) async throws {}
        func sendOneToOneMessage(_ packet: RatchetMessagePacket, recipient: Call.Participant) async throws {}
        func negotiateGroupIdentity(call: Call, sfuRecipientId: String) async throws {}
        func requestInitializeGroupCallRecipient(call: Call, sfuRecipientId: String) async throws {}
        func didEnd(call: Call, endState: CallStateMachine.EndState) async throws {}
    }

    private func makeSession() async -> RTCSession {
        await RTCSession(
            iceServers: [],
            username: "u",
            password: "p",
            delegate: Transport()
        )
    }

    private func makeCall(_ id: String) throws -> Call {
        try Call(
            sharedCommunicationId: id,
            sender: Call.Participant(secretName: "sender", nickname: "Sender", deviceId: "s"),
            recipients: [
                Call.Participant(secretName: "recipient", nickname: "Recipient", deviceId: "r")
            ]
        )
    }

    @Test("replacing blocked state consumer preserves successor ownership")
    func replacingBlockedStateConsumerPreservesSuccessor() async throws {
        let session = await makeSession()
        let firstCall = try makeCall("state-generation-first")
        let replacementCall = try makeCall("state-generation-replacement")

        try await session.createStateStream(with: firstCall)
        let firstGeneration = await session.stateTaskGeneration
        let firstTask = await session.stateTask
        #expect(firstTask != nil)

        try await session.createStateStream(with: replacementCall)
        let replacementGeneration = await session.stateTaskGeneration
        #expect(replacementGeneration > firstGeneration)
        #expect(firstTask?.isCancelled == true)

        for _ in 0..<20 {
            await Task.yield()
        }
        #expect(await session.stateTaskGeneration == replacementGeneration)
        #expect(await session.stateTask != nil)

        await session.shutdown(with: replacementCall)
        #expect(await session.stateTask == nil)
    }

    @Test("crypto stack generation is rebuilt after per-call teardown and never after destroySession")
    func cryptoStackGenerationLifecycle() async throws {
        let session = await makeSession()
        let originalPcRatchetManager = await session.pcRatchetManager
        let originalRatchetManager = await session.ratchetManager
        let originalTaskProcessor = await session.taskProcessor

        // Stable while no teardown has happened.
        #expect(await session.pcRatchetManager === originalPcRatchetManager)

        // Per-call teardown terminally shuts down both DoubleRatchetKit managers (their session
        // mutation gate closes permanently). The accessors must transparently provide a fresh
        // generation afterwards — before this existed, every call after the first in an app
        // session reused dead managers, all signaling jobs failed with CancellationError, and
        // the SFU never received an offer.
        await session.shutdown(with: nil)
        let rebuiltPcRatchetManager = await session.pcRatchetManager
        #expect(rebuiltPcRatchetManager !== originalPcRatchetManager)
        #expect(await session.ratchetManager !== originalRatchetManager)
        #expect(await session.taskProcessor !== originalTaskProcessor)
        #expect(await session.cryptoStackGeneration == 1)

        // Stable again until the next teardown.
        #expect(await session.pcRatchetManager === rebuiltPcRatchetManager)

        // destroySession is terminal: the final generation is shut down (deinit precondition
        // safety) and the accessors stop rebuilding.
        await session.destroySession()
        #expect(await session.isSessionDestroyed)
        let postDestroyPcRatchetManager = await session.pcRatchetManager
        #expect(await session.pcRatchetManager === postDestroyPcRatchetManager)
    }

    @Test("candidate drain replacement retires stale generation while replacement continues")
    func candidateDrainReplacementRetiresStaleGeneration() async {
        let session = await makeSession()
        let connectionId = "candidate-generation"

        let first = await session.testingInstallBlockedCandidateDrain(connectionId: connectionId)
        #expect(await session.testingCandidateDrainMaySend(
            connectionId: connectionId,
            generation: first.generation
        ))

        let replacement = await session.testingInstallBlockedCandidateDrain(connectionId: connectionId)
        #expect(first.task.isCancelled)
        #expect(replacement.generation > first.generation)
        #expect(await session.testingCandidateDrainMaySend(
            connectionId: connectionId,
            generation: first.generation
        ) == false)
        #expect(await session.testingCandidateDrainMaySend(
            connectionId: connectionId,
            generation: replacement.generation
        ))

        await session.cancelBufferedCandidateDrain(connectionId: connectionId)
        #expect(replacement.task.isCancelled)
        #expect(await session.testingCandidateDrainMaySend(
            connectionId: connectionId,
            generation: replacement.generation
        ) == false)
        await session.shutdown(with: nil)
    }

    @Test("Apple media attach recovery is event driven and teardown owned")
    func appleMediaAttachRecoverySourceGuards() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let relativePaths = [
            "Sources/PQSRTC/Views/Apple/Controllers/iOS/VideoCallViewController+UIKit.swift",
            "Sources/PQSRTC/Views/Apple/Controllers/macOS/VideoCallViewController+AppKit.swift",
        ]
        for relativePath in relativePaths {
            let source = try String(
                contentsOf: packageRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            for function in [
                "startRemoteScreenShareAttachRetry",
                "startRemoteRendererRecoveryIfNeeded",
                "startRemoteScreenShareRendererRecoveryIfNeeded",
                "startParticipantRendererRecoveryIfNeeded",
            ] {
                let body = try sourceBody(of: function, in: source)
                #expect(
                    !body.contains("Task.sleep"),
                    "\(relativePath) \(function) regressed to timer-driven media routing"
                )
            }
            for function in [
                "startRemoteRendererRecoveryIfNeeded",
                "startRemoteScreenShareRendererRecoveryIfNeeded",
                "startParticipantRendererRecoveryIfNeeded",
            ] {
                let body = try sourceBody(of: function, in: source)
                #expect(body.contains("inboundVideoFlowUpdateStream()"))
            }
            #expect(source.contains("pendingRemoteScreenShareActivation"))
            #expect(source.contains("sfuGroupSignalingStableStream()"))
            let signalingStable = try sourceBody(of: "startSfuGroupSignalingStableObservation", in: source)
            #expect(
                signalingStable.contains("assignExistingParticipantTracks(connectionId: connectionId)"),
                "\(relativePath) must assign mapped late-joiner tiles when SFU signaling becomes stable"
            )
            let teardown = try sourceBody(of: "tearDownCall", in: source)
            #expect(teardown.contains("pendingRemoteScreenShareActivation = nil"))
            #expect(teardown.contains("sfuGroupSignalingStableStreamTask?.cancel()"))
        }
    }

    @Test("Android coordinator task is generation-owned by call teardown")
    func androidCoordinatorLifecycleSourceGuard() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/PQSRTC/Views/Android/AndroidVideoCallController.swift"
            ),
            encoding: .utf8
        )
        #expect(source.contains("private var postRenegotiationCoordinatorTask: Task<Void, Never>?"))
        #expect(source.contains("private var postRenegotiationCoordinatorGeneration: UInt64 = 0"))
        let request = try sourceBody(of: "requestPostRenegotiationAttachCoordinator", in: source)
        #expect(request.contains("guard isRunning, isGroupCall else { return }"))
        let cancellation = try sourceBody(of: "cancelPostRenegotiationAttachCoordinator", in: source)
        #expect(cancellation.contains("postRenegotiationCoordinatorGeneration &+= 1"))
        #expect(cancellation.contains("postRenegotiationCoordinatorTask?.cancel()"))
        let teardown = try sourceBody(of: "markCallEndedLocally", in: source)
        #expect(teardown.contains("cancelPostRenegotiationAttachCoordinator()"))
        let signalingStable = try sourceBody(of: "handleSfuGroupSignalingBecameStable", in: source)
        #expect(signalingStable.contains("assignExistingParticipantTracks(connectionId: connectionId)"))
        #expect(signalingStable.contains("shouldDeferSfuGroupParticipantVideoAttach(for: connectionId)"))
    }

    @Test("Android screen-share layout recovery is Compose-generation driven")
    func androidScreenShareLayoutRecoveryUsesComposeGenerationEvents() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let controller = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/PQSRTC/Views/Android/AndroidVideoCallController.swift"
            ),
            encoding: .utf8
        )
        let compose = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/PQSRTC/Views/Android/AndroidLocalVideoCompose.swift"
            ),
            encoding: .utf8
        )

        #expect(controller.contains("beginParticipantVideoReconcileAfterScreenShareLayoutChange"))
        #expect(controller.contains("participantSurfaceDidUpdateLayout"))
        #expect(controller.contains("expectedComposeLayoutParticipantKeys.isSubset"))
        #expect(!controller.contains("screenShareLayoutReconcileTask"))
        #expect(!controller.contains("try await Task.sleep(nanoseconds: 100_000_000)"))
        #expect(compose.contains("onParticipantSurfaceLayout(view)"))
        #expect(compose.contains("_ = layoutGeneration"))
        #expect(compose.contains("onParticipantSurfaceLayout: (AndroidSampleCaptureView) -> Void"))
        #expect(!compose.contains("onParticipantSurfaceLayout(view, layoutGeneration)"))
        #expect(compose.contains("screenShareLayoutGeneration = generation"))
    }

    @Test("duplicate same-presenter activation enters refresh policy")
    func duplicateSamePresenterActivationEntersRefreshPolicy() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/PQSRTC/Views/Android/AndroidVideoCallController.swift"
            ),
            encoding: .utf8
        )
        let body = try sourceBody(of: "handleRemoteScreenTrackEvent", in: source)
        #expect(
            !body.contains("Ignoring duplicate remote screen-share activation"),
            "same-presenter isActive must not end in a naked ignore return"
        )
        #expect(
            body.contains("ScreenShareAttachPolicy.duplicateActivationDecision"),
            "same-presenter isActive must enter ScreenShareAttachPolicy.refreshExisting"
        )
        #expect(body.contains(".refreshExisting"))
    }

    @Test("Compose layout wait is not keyed on local isScreenSharing")
    func composeLayoutWaitIsNotKeyedOnLocalIsScreenSharing() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let compose = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/PQSRTC/Views/Android/AndroidLocalVideoCompose.swift"
            ),
            encoding: .utf8
        )
        #expect(
            !compose.contains("\"\\(isScreenSharing)-\\(hasActiveRemoteScreenShare)\""),
            "participant reconcile must not key on local isScreenSharing combined with remote share"
        )
        #expect(compose.contains("hasActiveRemoteScreenShare"))
    }

    @Test("participant surface layout callback remains one argument")
    func participantSurfaceLayoutCallbackRemainsOneArgument() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let compose = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/PQSRTC/Views/Android/AndroidLocalVideoCompose.swift"
            ),
            encoding: .utf8
        )
        #expect(compose.contains("onParticipantSurfaceLayout(view)"))
        #expect(compose.contains("onParticipantSurfaceLayout: (AndroidSampleCaptureView) -> Void"))
        #expect(!compose.contains("onParticipantSurfaceLayout(view, layoutGeneration)"))
    }

    @Test("Apple screen-share heal is not Task.yield owned")
    func appleScreenShareHealIsNotTaskYieldOwned() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let relativePaths = [
            "Sources/PQSRTC/Views/Apple/Controllers/iOS/VideoCallViewController+UIKit.swift",
            "Sources/PQSRTC/Views/Apple/Controllers/macOS/VideoCallViewController+AppKit.swift",
        ]
        for relativePath in relativePaths {
            let source = try String(
                contentsOf: packageRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            let body = try sourceBody(of: "schedulePostScreenShareLayoutHeal", in: source)
            #expect(
                !body.contains("Task.yield"),
                "\(relativePath) schedulePostScreenShareLayoutHeal must not own settlement with Task.yield"
            )
        }
    }

    @Test("waitForMountedVideoView has no 50ms poll")
    func waitForMountedVideoViewHasNo50msPoll() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let relativePaths = [
            "Sources/PQSRTC/Views/Apple/Controllers/iOS/VideoCallViewController+UIKit.swift",
            "Sources/PQSRTC/Views/Apple/Controllers/macOS/VideoCallViewController+AppKit.swift",
        ]
        for relativePath in relativePaths {
            let source = try String(
                contentsOf: packageRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            guard source.contains("func waitForMountedVideoView") else { continue }
            let body = try sourceBody(of: "waitForMountedVideoView", in: source)
            #expect(
                !body.contains("50_000_000"),
                "\(relativePath) waitForMountedVideoView must not poll with 50ms sleeps"
            )
            #expect(
                !body.contains("Task.sleep"),
                "\(relativePath) waitForMountedVideoView must not poll with Task.sleep"
            )
        }
    }

    @Test("Android local preview does not fill root then pad leading")
    func androidLocalPreviewDoesNotFillRootThenPadLeading() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let compose = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/PQSRTC/Views/Android/AndroidLocalVideoCompose.swift"
            ),
            encoding: .utf8
        )
        let localCompose = try sourceBody(of: "Compose", in: compose)
        let fillsRoot = localCompose.contains("context.modifier.fillMaxSize()")
        let padsLeadingTop = compose.contains(".padding(.leading, previewX)")
            && compose.contains(".padding(.top, previewY)")
        #expect(
            !(fillsRoot && padsLeadingTop),
            "local preview must not combine full-root fillMaxSize with leading/top positioning padding"
        )
    }

    @Test("Android screen rebind helper is called from SFU answer paths")
    func androidScreenRebindHelperIsCalledFromExchange() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let video = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/PQSRTC/RTCSession+Video.swift"),
            encoding: .utf8
        )
        #expect(video.contains("func rebindAndroidGroupRemoteParticipantScreenAfterSfuRenegotiationIfNeeded"))
        let exchange = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/PQSRTC/RTCSession+Exchange.swift"),
            encoding: .utf8
        )
        #expect(exchange.contains("rebindAndroidGroupRemoteParticipantScreenAfterSfuRenegotiationIfNeeded"))
        let helpers = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/PQSRTC/RTCSession+SDPHelpers.swift"),
            encoding: .utf8
        )
        #expect(helpers.contains("rebindAndroidGroupRemoteParticipantScreenAfterSfuRenegotiationIfNeeded"))
    }

    @Test("in-flight late-joiner track events are queued for post-settlement refresh")
    func lateJoinerTrackEventsAreQueuedDuringSfuRenegotiation() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sessionSource = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/PQSRTC/RTCSession.swift"),
            encoding: .utf8
        )
        let notify = try sourceBody(of: "notifyRemoteParticipantTrackChanged", in: sessionSource)
        #expect(notify.contains("shouldQueueSuppressedParticipantTrackEventForPostRenegotiationRefresh"))
        #expect(notify.contains("queueParticipantCameraRendererSinkRefresh("))

        let videoSource = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/PQSRTC/RTCSession+Video.swift"),
            encoding: .utf8
        )
        let appleRender = try sourceBody(of: "renderRemoteVideoForParticipant", in: videoSource)
        #expect(appleRender.contains("queueParticipantCameraRendererSinkRefresh("))
    }

    private func sourceBody(of functionName: String, in source: String) throws -> String {
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

private extension RTCSession {
    func testingInstallBlockedCandidateDrain(
        connectionId: String
    ) -> (generation: UInt64, task: Task<Void, Never>) {
        let key = connectionId.normalizedConnectionId
        readyForCandidatesByConnectionId[key] = nil
        cancelBufferedCandidateDrain(connectionId: key)
        readyForCandidatesByConnectionId[key] = true
        let generation = (bufferedCandidateDrainGenerationByConnectionId[key] ?? 0) &+ 1
        bufferedCandidateDrainGenerationByConnectionId[key] = generation
        let task = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
        }
        bufferedCandidateDrainTasksByConnectionId[key] = task
        return (generation, task)
    }

    func testingCandidateDrainMaySend(connectionId: String, generation: UInt64) -> Bool {
        let key = connectionId.normalizedConnectionId
        return bufferedCandidateDrainGenerationByConnectionId[key] == generation
            && readyForCandidatesByConnectionId[key] == true
            && bufferedCandidateDrainTasksByConnectionId[key]?.isCancelled == false
    }
}
