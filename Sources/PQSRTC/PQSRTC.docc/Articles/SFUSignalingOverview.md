# SFU signaling overview (PQSRTC)

PQSRTC treats the SFU as a **control plane** (signaling, roster, key distribution) and a **WebRTC media plane** (single `RTCPeerConnection` per app for SFU mode in typical integrations). End-to-end protection of signaling uses the same **Double Ratchet** stack as your messaging session; plaintext SDP and metadata are only handled **after** decrypt inside the session.

## Entry points (conceptual)

- **Outbound / negotiated start:** `createGroupCall`, ``createSFUIdentity``, ``groupCallNegotiation``, then media bootstrap when identities and transport are ready.
- **Inbound control messages:** your transport decodes wire payloads into ``RTCGroupCall/ControlMessage`` and calls ``RTCSession/handleControlMessage(_:)`` for answers, offers, candidates, and roster messages.
- **Ratchet-encrypted channel:** the `TaskProcessor` actor performs encrypt/decrypt; decrypted payloads are dispatched into `RTCSession`’s internal stream handler (see `TaskProcessor` + `RTCSession+GroupCall` in source).

## Flags and post-cipher handshake

- Control-plane packets use ``PacketFlag`` (e.g. ``PacketFlag/offer``, ``PacketFlag/answer``, ``PacketFlag/candidate``, ``PacketFlag/handshakeComplete``). The **`.handshakeComplete`** case carries an updated `Call` / identity payload **after** the initial cipher exchange—it is not a renegotiation offer. Host routing must not treat it as a second remote “offer” for 1:1.
- The SFU or transport may **deliver duplicate** `.handshakeComplete` ciphertexts; PQSRTC deduplicates identical ratchet material per connection in ``TaskProcessor`` to avoid a second decrypt after the ratchet has advanced (which would fail with a core-crypto error).

## Server contract

- The **SwiftSFU** process defines IRC-backed SFU behavior, room routing, and relay rules. See the SwiftSFU documentation catalog in the `swift-sfu` package for environment variables, control-plane behavior, and client-facing expectations.
- The **Nudge** / NeedleTail app bridges IRC SFU messages into PQSRTC; your host must key rooms consistently (`sharedCommunicationId`, `#` channel form, and normalized connection ids) as the SDK expects.

## See also

- <doc:HostAppCallKitAndSFU> for **iOS CallKit** ordering with SFU
- <doc:SfuRemoteVideoFrameE2EE> for **remote video** and per-participant **frame E2EE** (SFU)
- <doc:Getting-Started>
- ``RTCSession``
- ``RTCGroupCall``
