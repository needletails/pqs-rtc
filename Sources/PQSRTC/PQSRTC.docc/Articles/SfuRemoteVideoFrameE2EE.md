# Remote video and per-participant frame E2EE on the SFU

When **frame-level E2EE** is enabled (``RTCFrameEncryptionKeyMode/perParticipant``) on a **server SFU** call, remote **video** (and audio) can appear to work at the WebRTC layer—ICE connected, receivers and tracks present—while **no frames decrypt** or the pipeline **never shows picture**. This article documents the **identity and labeling rules** PQSRTC enforces so receiver **FrameCryptor** instances use the same participant ids as receive-key provisioning and the remote sender's local sender slot.

> **Scope:** This is the **client SDK** contract. SwiftSFU forwards RTP; it does not pick frame keys. Regressions here are usually either:
> - **E2EE id mismatch** (this article's primary focus), or
> - **SDP profile-level mismatch** (even with frame encryption disabled), covered below.

## Important: remote video can also fail with frame encryption disabled

The historical 1:1 SFU outage had **two** independent classes of failures:

1. **Per-participant FrameCryptor identity mismatch** (sections below).
2. **SDP H264 profile-level rewrite instability** in the non-E2EE path.

Even when frame encryption is disabled, forcing an unstable H264 profile-level can lead to sender stalls
or peer/SFU compatibility issues that present as black/frozen remote video. PQSRTC now caps:

- `profile-level-id=42e034` -> `42e028`

See `RTCSession+SDPHelpers.modifySDP` for the in-code rationale comment.

## What went wrong (historical bug)

Several independent issues stacked into “**no remote video**” with encryption on:

1. **Room id vs peer `secretName`** — Group/SFU ``RTCConnection`` objects often use the **room** (`sharedCommunicationId` / `#<uuid>`) as the signaling **routing** `recipient`. Per-participant frame keys, however, must be provisioned under the participant that owns the media: `localParticipantId` for outbound frames, and the remote peer's `secretName` for inbound frames. If the room/shared slot was used for a per-participant 1:1 SFU call, FrameCryptors looked up keys under `echo`/`nudge` or UUID **msid** labels and got **missingKey** forever.

2. **Stale `call_cipher` identity props** — A merged `Call` can still contain the remote peer's
`frameIdentityProps`. Outbound `call_cipher` must refresh the payload with this device's local
frame/signaling props, otherwise the receiver derives its receive media ratchet against the wrong
identity.

3. **Refreshed receive ratchet index** — A new `call_cipher` ciphertext is a fresh bootstrap. If
the receiver reuses the old receive media-ratchet session, it derives key index `1` while the sender
restarted at index `0`. The receive session id therefore includes the inbound ciphertext
fingerprint.

4. **`call.sender` rewritten on answer** — On the callee, `resolveProperRecipient` can make `call.sender` the **local** user. Using `call.sender` alone to infer “who sends media” could provision receive keys under the **local** id; the real remote stream still needed the peer’s key.

5. **WebRTC stream labels (`msid`)** — SFU/native stacks may publish recv stream ids as `secretName_` (trailing underscore) while keys are stored under `secretName`. Binding a cryptor to `echo_` when keys exist only for `echo` yields **no decrypted frames**.

6. **UUID-like placeholder stream ids** — Before renegotiation stabilizes, recv labels can be **random UUIDs**. Binding a receiver FrameCryptor to that UUID without a **key alias** or **delay-until-stable** logic caused `missingKey` spam or permanent mismatch.

7. **Self-loop / local id on recv** — Sometimes the SFU surfaces a recv track labeled like the **local** participant. A receiver FrameCryptor for **self** has no decrypt key for “remote” media; PQSRTC **skips** that binding.

8. **1:1 relay vs conference (`conf-`)** — Ephemeral UUID **1:1 relay** rooms must use **peer-based** key slots. **`conf-` conference** rooms must **not** be treated as “true 1:1 SFU” or we remap stream ids to the room string and **break** E2EE key lookup.

## Requirements and behavior (do not regress)

### A. Know the room shape: `isTrueOneToOneSfuRoom`

PQSRTC uses the internal `isTrueOneToOneSfuRoom(call:)` helper on ``RTCSession`` to decide **1:1-over-SFU relay** vs **multi-party / conference**:

- **True 1:1 SFU:** ephemeral UUID communication id, wire id aligned with Nudge’s relay shape, at most **one distinct** recipient `secretName` (duplicate device rows for the same peer still count as 1:1).
- **Not** 1:1: multiple distinct recipient names, or `conf-…` shared communication ids, etc.

**Keys:** ``RTCSession/setMessageKey`` provisions the local sender key under `connection.localParticipantId` in per-participant mode. It does not mirror that key into the room id or remote peer slot. ``RTCSession/setReceivingMessageKey`` provisions the receive key under the resolved remote track owner.

### B. Resolve the **track owner** for keys: `remoteTrackOwnerParticipantId`

Inbound media keys must be provisioned for the participant who **owns** the remote RTP streams, not necessarily `connection.remoteParticipantId` when that field holds the **room** id for SFU routing.

Implementation: `remoteTrackOwnerParticipantId(connection:call:)` in `RTCSession+RTCCipherTransport` — read the in-source documentation; it encodes the **room-routed vs peer** distinction.

### C. Receiver FrameCryptor participant id (peer notifications path)

For **group / SFU** connections in per-participant mode, the receiver binding uses `receiverParticipantIdOverrideForE2EE` (`RTCSession+PeerNotificationsHandler`), which:

- **Remaps UUID-like** stream ids in **true 1:1 SFU** rooms to `remoteTrackOwnerParticipantId` / effective remote so cryptor id matches receive-key provisioning and the remote sender's local sender key.
- **Normalizes** `secretName_` → `secretName` via `normalizedReceiverFrameKeyParticipantIdForSfuUnderscoreStreamLabel` when the label matches the effective remote.
- **Skips** cryptors that would bind to the **local** participant id (`shouldSkipGroupReceiverFrameCryptor`).
- **Delays** binding when the only known id is still a **UUID placeholder** (`shouldDelayReceiverFrameCryptorBindingForUuidPlaceholder`) so we do not permanently attach to a dead id before stable labels arrive.
- **Clears UUID-aliased** cryptors when rebinding to a stable id (`clearUuidAliasedReceiverCryptors`) so two FrameCryptors never share one `RTPReceiver` (undefined behavior in WebRTC).

### D. Optional UUID key alias (true 1:1 only)

`tryProvisionUuidAliasFrameKeyIfPossible` may copy the peer’s provisioned key to a **UUID** slot so an early FrameCryptor can decrypt **before** msid stabilizes—**only** when unambiguous (true 1:1); multi-party refuses to guess.

### E. Group, conference, and multi-party

- Do **not** apply 1:1 UUID/underscore remaps in ways that force **room id** into per-peer key maps incorrectly; `isTrueOneToOneSfuRoom` must stay **false** for `conf-` rooms even with one recipient.
- Multi-recipient rooms: media uses app-injected per-sender frame keys. Install your own sender key
  under the local participant id, and install each remote sender key under that remote sender id.
  Never mirror a sender key into room or peer slots.
- Pairwise `call_cipher` is intentionally ignored for channel-backed group and `conf-` media
  keying. See <doc:GroupSfuFrameE2EE>.

## Verification

- **Unit tests:** `Tests/PQSRTCCompiledSwiftTests/RTCSessionCryptoKeyResolutionTests.swift` — underscore msid, 1:1 vs `conf-`, UUID delay, `setMessageKey` local sender targeting.
- **Runtime symptoms of regression:** ICE `connected`, tracks attached, **zero** decrypted video frames; logs around **missingKey** / FrameCryptor with ids that are room UUIDs or `foo_` when keys are under `foo`.

## Related code (source of truth)

- `RTCSession+PeerNotificationsHandler.swift` — receiver overrides, delay, skip-local, UUID cleanup
- `RTCSession+RTCCipherTransport.swift` — `isTrueOneToOneSfuRoom`, `remoteTrackOwnerParticipantId`, sender/receive key provisioning
- `RTCSession+SDPHelpers.swift` — H264 profile-level cap used to avoid 1:1 SFU sender/interop stalls

## See also

- <doc:OneToOneSfuFrameE2EE>
- <doc:GroupSfuFrameE2EE>
- <doc:SFUSignalingOverview>
- <doc:HostAppCallKitAndSFU> (audio session ordering; separate from frame keys but same calls)
- ``RTCFrameEncryptionKeyMode``
