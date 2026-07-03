//
//  ScreenShareGroupCallContract.swift
//  pqs-rtc
//
//  Canonical behavior for SFU group-call screen sharing.
//  Tests and SDP policy are written against this contract — not against production logs.
//

import Foundation

/// Roles and signaling rules for conference / group SFU screen share.
///
/// Client-side SDP policy (`ScreenShareGroupCallSDPPolicy`) and SFU relay obligations
/// (`ScreenShareGroupCallSFUContract` in SwiftSFU) must stay aligned with this spec.
/// General call join, 1:1, and voice-only flows are intentionally out of scope.
public enum ScreenShareGroupCallContract: Sendable {
    // MARK: - Topology

    /// Fixed BUNDLE mids on every SFU group leg.
    public enum MediaMid: String, Sendable, CaseIterable {
        case audio = "0"
        case camera = "1"
        case screen = "2"
    }

    /// Who may originate SDP offers in group/conference SFU mode.
    public enum OfferOrigin: Sendable {
        /// Initial join only (`beginGroupCallMediaAfterSfuRegistrationIfNeeded`).
        case clientMediaBootstrap
        /// Sharer toggles capture (`sendGroupCallOffer` after add/remove screen track).
        case sharerScreenToggle
        /// SFU adds/removes a forwarded track (`handleRenegotiationOffer` on viewers).
        case sfuReceiverRefresh
    }

    /// A single leg in the share lifecycle.
    public enum SignalingLeg: Sendable {
        /// Sharer → SFU offer after capture starts.
        case sharerStartShare(participantId: String, roomId: String)
        /// SFU → viewer offer advertising an active remote screen.
        case sfuForwardShareToViewer(sharerId: String, viewerId: String, roomId: String)
        /// Viewer → SFU answer while not sharing locally.
        case viewerAnswerWhileReceiving(sharerId: String, viewerIsSharing: Bool)
        /// Sharer → SFU offer after capture stops.
        case sharerStopShare(participantId: String, roomId: String)
        /// SFU → viewer offer after remote screen stopped.
        case sfuForwardStopToViewer(formerSharerId: String, viewerId: String, roomId: String)
        /// Sharer ← SFU answer to a stop-share offer.
        case sharerAcceptStopAnswer(participantId: String, roomId: String)
        /// New sharer → SFU ``PacketFlag/screenSharePreempt`` before local capture starts.
        case clientPreemptPriorSharer(newSharerId: String, formerSharerId: String, roomId: String)
    }

    // MARK: - Naming

    public static func screenStreamLabel(participantId: String) -> String {
        "\(RTCSession.screenTrackPrefix)\(participantId)"
    }

    public static func screenTrackId(participantId: String, roomId: String) -> String {
        "\(screenStreamLabel(participantId: participantId))_\(roomId)"
    }

    public static func cameraTrackId(participantId: String, roomId: String) -> String {
        "video_\(participantId)_\(roomId)"
    }

    public static func audioTrackId(participantId: String, roomId: String) -> String {
        "audio_\(participantId)_\(roomId)"
    }

    // MARK: - Global rules

    /// Only one room participant may publish screen media at a time.
    public static let exclusiveSharePerRoom = true

    /// Viewers must never originate group renegotiation offers for remote track changes.
    public static let viewersAnswerSfuOffersOnly = true

    /// Sharers must send an offer after both start and stop of capture.
    public static let sharerRenegotiatesOnStartAndStop = true

    /// After ``SignalingLeg/clientPreemptPriorSharer``, wait until the former sharer's stop is
    /// explicit in SDP (`a=inactive` on mid=2). Relay-style offers that omit msid labels must not
    /// be treated as "stopped" while RTP may still be active.
    public static let preemptWaitRequiresExplicitStopInSDP = true

    /// When the SFU relays a stale `sendrecv` screen leg after preempt, treat a sustained flat
    /// screen mid (while audio/camera still advances) as stop-complete so the next sharer can start.
    public static let preemptWaitAllowsIngressCeasedFallback = true

    /// Minimum seconds screen mid RTP must remain flat before the ingress-ceased fallback fires.
    public static let preemptWaitIngressCeasedMinimumFlatSeconds: TimeInterval = 3.0

    /// Viewers defer answering SFU relay offers that duplicate the camera SSRC on any inbound
    /// screen relay mid until a distinct screen SSRC is advertised (placeholder refresh from the SFU).
    public static let deferPlaceholderDuplicateScreenSsrcOffers = true

    /// After the SFU answers a local screen-share offer, the sharer restores `sendOnly` on mid=2
    /// and ensures the outbound screen FrameCryptor remains bound (stale connection snapshots must
    /// not wipe cryptor state written by `createEncryptedFrame`).
    public static let sharerRestoresOutboundScreenAfterSfuAnswer = true

    /// Only one inbound SFU renegotiation answer may be in flight per connection; duplicates queue
    /// until signaling is stable so viewer transceivers are not torn down mid-negotiation.
    public static let serializeConcurrentSfuRenegotiationOffers = true

    // MARK: - SDP invariants

    public struct SDPLegExpectation: Sendable, Equatable {
        public var midDirections: [MediaMid: String]
        public var advertisedRemoteSharers: [String]
        public var activeRemoteScreenMids: Set<String>
        public var screenMsidParticipant: String?

        public init(
            midDirections: [MediaMid: String],
            advertisedRemoteSharers: [String] = [],
            activeRemoteScreenMids: Set<String> = [],
            screenMsidParticipant: String? = nil
        ) {
            self.midDirections = midDirections
            self.advertisedRemoteSharers = advertisedRemoteSharers
            self.activeRemoteScreenMids = activeRemoteScreenMids
            self.screenMsidParticipant = screenMsidParticipant
        }
    }

    public struct ValidationIssue: Sendable, Equatable, CustomStringConvertible {
        public var message: String
        public var description: String { message }
    }

    /// Expected post-process SDP for each contract leg.
    public static func expectation(for leg: SignalingLeg) -> SDPLegExpectation {
        switch leg {
        case let .sharerStartShare(participantId, _):
            return SDPLegExpectation(
                midDirections: [
                    .audio: "sendrecv",
                    .camera: "sendrecv",
                    .screen: "sendonly"
                ],
                advertisedRemoteSharers: [],
                activeRemoteScreenMids: [MediaMid.screen.rawValue],
                screenMsidParticipant: participantId
            )
        case let .sfuForwardShareToViewer(sharerId, viewerId, _):
            _ = viewerId
            return SDPLegExpectation(
                midDirections: [
                    .audio: "sendrecv",
                    .camera: "sendrecv",
                    .screen: "sendonly"
                ],
                advertisedRemoteSharers: [sharerId],
                activeRemoteScreenMids: [MediaMid.screen.rawValue],
                screenMsidParticipant: sharerId
            )
        case let .viewerAnswerWhileReceiving(sharerId, viewerIsSharing):
            if viewerIsSharing {
                // Viewer is also sharing: do not force recvonly on remote screen mid.
                return SDPLegExpectation(
                    midDirections: [
                        .audio: "sendrecv",
                        .camera: "sendrecv",
                        .screen: "sendrecv"
                    ],
                    advertisedRemoteSharers: [],
                    activeRemoteScreenMids: []
                )
            }
            _ = sharerId
            return SDPLegExpectation(
                midDirections: [
                    .audio: "sendrecv",
                    .camera: "sendrecv",
                    .screen: "recvonly"
                ],
                advertisedRemoteSharers: [],
                activeRemoteScreenMids: []
            )
        case .sharerStopShare(_, _):
            return SDPLegExpectation(
                midDirections: [
                    .audio: "sendrecv",
                    .camera: "sendrecv",
                    .screen: "inactive"
                ],
                advertisedRemoteSharers: [],
                activeRemoteScreenMids: [],
                screenMsidParticipant: nil
            )
        case let .sfuForwardStopToViewer(formerSharerId, viewerId, _):
            _ = formerSharerId
            _ = viewerId
            return SDPLegExpectation(
                midDirections: [
                    .audio: "sendrecv",
                    .camera: "sendrecv",
                    .screen: "recvonly"
                ],
                advertisedRemoteSharers: [],
                activeRemoteScreenMids: []
            )
        case let .sharerAcceptStopAnswer(participantId, _):
            _ = participantId
            return SDPLegExpectation(
                midDirections: [
                    .audio: "sendrecv",
                    .camera: "sendrecv",
                    .screen: "inactive"
                ],
                advertisedRemoteSharers: [],
                activeRemoteScreenMids: []
            )
        case let .clientPreemptPriorSharer(newSharerId, formerSharerId, _):
            _ = newSharerId
            _ = formerSharerId
            // Control-plane only: no SDP mutation on the preempt sender.
            return SDPLegExpectation(midDirections: [:])
        }
    }

    /// Validates processed SDP against the contract leg.
    public static func validate(
        processedSdp: String,
        leg: SignalingLeg,
        viewerParticipantId: String? = nil,
        resolveParticipantId: ((String) -> String?)? = nil
    ) -> [ValidationIssue] {
        let expected = expectation(for: leg)
        var issues: [ValidationIssue] = []

        for (mid, wantDirection) in expected.midDirections {
            let got = direction(forMid: mid.rawValue, in: processedSdp)
            if got != wantDirection {
                issues.append(ValidationIssue(
                    message: "mid \(mid.rawValue): expected a=\(wantDirection), got a=\(got ?? "nil")"
                ))
            }
        }

        let activeMids = RTCSession.activeScreenShareVideoMids(in: processedSdp)
        if activeMids != expected.activeRemoteScreenMids {
            issues.append(ValidationIssue(
                message: "active screen mids: expected \(expected.activeRemoteScreenMids.sorted()), got \(activeMids.sorted())"
            ))
        }

        if let viewerParticipantId, let resolveParticipantId {
            let sharers = ScreenShareGroupCallSDPPolicy.remoteScreenSharesInInboundOffer(
                processedOfferSdp: processedSdp,
                viewerParticipantId: viewerParticipantId,
                resolveParticipantId: resolveParticipantId
            ).map(\.participantId)
            if sharers != expected.advertisedRemoteSharers {
                issues.append(ValidationIssue(
                    message: "advertised remote sharers: expected \(expected.advertisedRemoteSharers), got \(sharers)"
                ))
            }
        }

        if let screenParticipant = expected.screenMsidParticipant {
            let label = screenStreamLabel(participantId: screenParticipant)
            if !processedSdp.contains("a=msid:\(label)") {
                issues.append(ValidationIssue(
                    message: "missing screen msid stream label a=msid:\(label)"
                ))
            }
        }

        return issues
    }

    public static func direction(forMid targetMid: String, in sdp: String) -> String? {
        var currentMid: String?
        for rawLine in sdp
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("m=") {
                currentMid = nil
            } else if line.hasPrefix("a=mid:") {
                currentMid = String(line.dropFirst("a=mid:".count))
            } else if currentMid == targetMid,
                      ["a=sendrecv", "a=sendonly", "a=recvonly", "a=inactive"].contains(line) {
                return String(line.dropFirst("a=".count))
            }
        }
        return nil
    }
}
