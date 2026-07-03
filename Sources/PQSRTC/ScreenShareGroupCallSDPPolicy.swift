//
//  ScreenShareGroupCallSDPPolicy.swift
//  pqs-rtc
//
//  Pure SDP policy for SFU group-call screen share renegotiation.
//  Centralizes modifySDP parameter selection so share/stop/handoff scenarios
//  can be tested without WebRTC peer connections.
//

import Foundation

/// SDP processing rules for SFU group-call screen-share renegotiation.
///
/// Implements `ScreenShareGroupCallContract` on the client: every method here
/// corresponds to a signaling leg the contract tests assert.
public enum ScreenShareGroupCallSDPPolicy: Sendable {
    /// Inputs to `RTCSession.modifySDP` when applying a locally generated SFU group answer.
    public struct AnswerModificationPlan: Sendable, Equatable {
        public var preserveVideoDirectionsForMids: Set<String>
        public var forceReceiveOnlyVideoMids: Set<String>

        public init(
            preserveVideoDirectionsForMids: Set<String>,
            forceReceiveOnlyVideoMids: Set<String>
        ) {
            self.preserveVideoDirectionsForMids = preserveVideoDirectionsForMids
            self.forceReceiveOnlyVideoMids = forceReceiveOnlyVideoMids
        }
    }

    /// Computes `modifySDP` parameters for `createAnswer` / `handleRenegotiationOffer` answer paths.
    public static func answerModificationPlan(
        remoteOfferSdp: String,
        localIsSharingScreen: Bool
    ) -> AnswerModificationPlan {
        let remoteScreenShareVideoMids = RTCSession.screenShareVideoMids(in: remoteOfferSdp)
        let activeRemoteScreenShareVideoMids = RTCSession.activeScreenShareVideoMids(in: remoteOfferSdp)
        let remotePlaceholderCameraVideoMids = RTCSession.receiveOnlyVideoMidsWithoutLocalMedia(in: remoteOfferSdp)
            .union(RTCSession.inactiveVideoMidsWithoutLocalMedia(in: remoteOfferSdp))
        let forceReceiveOnlyVideoMids = localIsSharingScreen ? [] : activeRemoteScreenShareVideoMids
        let preserveVideoDirectionsForMids = remoteScreenShareVideoMids.union(remotePlaceholderCameraVideoMids)
        return AnswerModificationPlan(
            preserveVideoDirectionsForMids: preserveVideoDirectionsForMids,
            forceReceiveOnlyVideoMids: forceReceiveOnlyVideoMids
        )
    }

    /// Applies the inbound SFU renegotiation offer policy before `setRemoteDescription`.
    public static func preprocessInboundRenegotiationOffer(
        session: RTCSession,
        remoteOfferSdp: String,
        supportsVideo: Bool
    ) async -> String {
        let sanitized = sanitizedInboundSfuOfferRemovingRelayPlaceholderDuplicateSsrc(
            remoteOfferSdp: remoteOfferSdp
        )
        // SFU-authored audio directions are authoritative. Upgrading a relay `sendonly` audio
        // m-line to `sendrecv` before setRemoteDescription lets the local answer claim a send
        // path on the relay mid; the SFU reflects that phantom track back as a new source and
        // audio m-lines grow without bound (1:1 demux failure at mid 10). Upgrading the local
        // publish slot (`recvonly`) opens a phantom receive path with no FrameCryptor, which
        // plays ciphertext as garbled audio in group rooms.
        return await session.modifySDP(
            sdp: sanitized,
            hasVideo: supportsVideo,
            stripSsrcLines: false,
            preserveAudioDirectionsForMids: RTCSession.audioMids(in: sanitized)
        )
    }

    /// Applies the outbound SFU group-call offer policy before `setLocalDescription`.
    public static func preprocessOutboundGroupCallOffer(
        session: RTCSession,
        rawOfferSdp: String,
        supportsVideo: Bool,
        isGroupCall: Bool
    ) async -> String {
        // The contract screen slot (mid=2) direction is always authored natively:
        // libwebrtc emits sendrecv/sendonly while the local screen track is attached and
        // inactive/recvonly after stop. The generic `hasVideo` camera upgrade must never
        // touch it — flipping a stop offer's `mid=2 a=inactive` (with leftover msid/ssrc
        // attributes) back to `a=sendrecv` makes the SFU re-forward the just-stopped
        // share, resurrecting the screen-share UI on every viewer.
        await session.modifySDP(
            sdp: rawOfferSdp,
            hasVideo: supportsVideo,
            stripSsrcLines: false,
            vp8OnlyVideo: isGroupCall,
            preserveVideoDirectionsForMids: [ScreenShareGroupCallContract.MediaMid.screen.rawValue]
        )
    }

    /// Applies the SFU group-call answer policy before `setLocalDescription`.
    public static func applyAnswerModificationPlan(
        session: RTCSession,
        rawAnswerSdp: String,
        remoteOfferSdp: String,
        localIsSharingScreen: Bool,
        supportsVideo: Bool,
        isGroupCall: Bool
    ) async -> String {
        let plan = answerModificationPlan(
            remoteOfferSdp: remoteOfferSdp,
            localIsSharingScreen: localIsSharingScreen
        )
        let preserveFromRawAnswer = RTCSession.inactiveVideoMidsWithoutLocalMedia(in: rawAnswerSdp)
            .union(RTCSession.receiveOnlyVideoMidsWithoutLocalMedia(in: rawAnswerSdp))
        // Answer audio directions were computed by WebRTC from offer ∩ transceiver and must not
        // be upgraded. Rewriting the local publish slot's `sendonly` to `sendrecv` claims a
        // receive path the SFU never offered; unsignaled inbound RTP then demuxes onto the local
        // mic m-line whose receiver has no FrameCryptor, and encrypted Opus plays as garbled
        // audio. Rewriting relay `recvonly` to `sendrecv` mints phantom send SSRCs that the SFU
        // reflects back, growing audio m-lines until 1:1 renegotiation fails.
        return await session.modifySDP(
            sdp: rawAnswerSdp,
            hasVideo: supportsVideo,
            stripSsrcLines: false,
            vp8OnlyVideo: isGroupCall,
            preserveAudioDirectionsForMids: RTCSession.audioMids(in: rawAnswerSdp),
            preserveVideoDirectionsForMids: plan.preserveVideoDirectionsForMids.union(preserveFromRawAnswer),
            forceReceiveOnlyVideoMids: plan.forceReceiveOnlyVideoMids
        )
    }

    /// Parses remote screen shares from a processed inbound SFU offer (msid-prefixed and relay-style).
    static func remoteScreenSharesInInboundOffer(
        processedOfferSdp: String,
        viewerParticipantId: String,
        resolveParticipantId: @escaping (String) -> String?
    ) -> [RTCSession.AdvertisedRemoteScreenShare] {
        let msidStyle = RTCSession.advertisedRemoteScreenShares(
            in: processedOfferSdp,
            localParticipantId: viewerParticipantId,
            resolveParticipantId: resolveParticipantId
        )
        let relayStyle = RTCSession.advertisedRelayStyleRemoteScreenShares(
            in: processedOfferSdp,
            localParticipantId: viewerParticipantId,
            participantFromStreamLabel: resolveParticipantId
        )
        var merged: [RTCSession.AdvertisedRemoteScreenShare] = []
        var seen = Set<String>()
        for share in msidStyle + relayStyle {
            guard !seen.contains(share.participantId) else { continue }
            seen.insert(share.participantId)
            merged.append(share)
        }
        return merged
    }

    /// Normalizes an SFU answer against the sharer's local offer before `setRemoteDescription`.
    public static func preprocessInboundAnswerForLocalOffer(
        answerSdp: String,
        localOfferSdp: String,
        session: RTCSession,
        supportsVideo: Bool,
        isGroupCall: Bool
    ) async -> String {
        let normalized = RTCSession.normalizeAnswerVideoDirectionsForLocalOffer(
            answerSdp: answerSdp,
            localOfferSdp: localOfferSdp
        )
        // The SFU's answer audio directions are authoritative (recvonly on our publish slot).
        // Upgrading them to sendrecv before setRemoteDescription makes the client believe the
        // SFU sends on our mic m-line and creates an unkeyed receive path (garbled audio).
        return await session.modifySDP(
            sdp: normalized,
            hasVideo: supportsVideo,
            stripSsrcLines: false,
            vp8OnlyVideo: isGroupCall,
            preserveAudioDirectionsForMids: RTCSession.audioMids(in: normalized),
            preserveVideoDirectionsForMids: RTCSession.videoMids(in: normalized)
        )
    }

    // MARK: - Preempt / relay guards

    /// True when a preempted remote sharer should be treated as stopped for exclusive-share wait.
    public static func shouldTreatRemoteSharerAsStoppedAfterPreempt(
        participantId: String,
        stopWasRequested: Bool,
        explicitInactiveParticipantIds: [String],
        screenIngressCeased: Bool = false
    ) -> Bool {
        guard stopWasRequested else { return false }
        let participantKey = RTCSession.conferenceParticipantIdentityKey(participantId)
        guard !participantKey.isEmpty else { return false }

        if explicitInactiveParticipantIds.contains(where: {
            RTCSession.conferenceParticipantIdentityKey($0) == participantKey
        }) {
            return true
        }

        if screenIngressCeased,
           ScreenShareGroupCallContract.preemptWaitAllowsIngressCeasedFallback {
            return true
        }

        return !ScreenShareGroupCallContract.preemptWaitRequiresExplicitStopInSDP
    }

    /// First `a=ssrc:` line in the `m=` section for `targetMid`, if any.
    public static func firstRtpSsrc(forMid targetMid: String, in sdp: String) -> UInt32? {
        var currentMid: String?
        for rawLine in sdp
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("m=") {
                currentMid = nil
            } else if line.hasPrefix("a=mid:") {
                currentMid = String(line.dropFirst("a=mid:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else if currentMid == targetMid, line.hasPrefix("a=ssrc:") {
                let payload = String(line.dropFirst("a=ssrc:".count))
                let token = payload.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
                return UInt32(token)
            }
        }
        return nil
    }

    /// Video mids in an inbound SFU offer whose first RTP SSRC duplicates the camera mid SSRC.
    public static func relayVideoMidsWithPlaceholderDuplicateCameraSsrc(in remoteOfferSdp: String) -> Set<String> {
        guard let cameraSsrc = firstRtpSsrc(
            forMid: ScreenShareGroupCallContract.MediaMid.camera.rawValue,
            in: remoteOfferSdp
        ),
        cameraSsrc > 0 else {
            return []
        }

        let relayMids = RTCSession.sfuRelayIncomingScreenShareVideoMids(in: remoteOfferSdp)
            .union(RTCSession.activeScreenShareVideoMids(in: remoteOfferSdp))
        return Set(relayMids.compactMap { mid -> String? in
            guard mid != ScreenShareGroupCallContract.MediaMid.camera.rawValue,
                  let relaySsrc = firstRtpSsrc(forMid: mid, in: remoteOfferSdp),
                  relaySsrc > 0,
                  relaySsrc == cameraSsrc else {
                return nil
            }
            return mid
        })
    }

    /// SFU relay sometimes publishes a placeholder offer where an inbound screen mid reuses the camera SSRC.
    public static func sfuRelayScreenOfferUsesPlaceholderDuplicateSsrc(remoteOfferSdp: String) -> Bool {
        guard ScreenShareGroupCallContract.deferPlaceholderDuplicateScreenSsrcOffers else { return false }
        return !relayVideoMidsWithPlaceholderDuplicateCameraSsrc(in: remoteOfferSdp).isEmpty
    }

    /// Removes placeholder `a=ssrc:` / `a=ssrc-group:` lines on relay screen mids that duplicate the camera SSRC.
    public static func sanitizedInboundSfuOfferRemovingRelayPlaceholderDuplicateSsrc(
        remoteOfferSdp: String
    ) -> String {
        let duplicateMids = relayVideoMidsWithPlaceholderDuplicateCameraSsrc(in: remoteOfferSdp)
        guard !duplicateMids.isEmpty else { return remoteOfferSdp }

        var currentMid: String?
        var output: [String] = []
        let normalized = remoteOfferSdp
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        for rawLine in normalized.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("m=") {
                currentMid = nil
                output.append(rawLine)
                continue
            }
            if line.hasPrefix("a=mid:") {
                currentMid = String(line.dropFirst("a=mid:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                output.append(rawLine)
                continue
            }
            if let currentMid, duplicateMids.contains(currentMid),
               line.hasPrefix("a=ssrc:") || line.hasPrefix("a=ssrc-group:") {
                continue
            }
            output.append(rawLine)
        }
        return output.joined(separator: "\r\n")
    }
}
