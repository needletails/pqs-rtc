# SFU signaling overview (PQSRTC)

PQSRTC treats the SFU as a **control plane** (signaling and roster) and a **WebRTC media plane**
(single `RTCPeerConnection` per app for SFU mode in typical integrations). End-to-end protection
of signaling uses the same **Double Ratchet** stack as your messaging session; plaintext SDP and
metadata are only handled **after** decrypt inside the session. Group media frame keys are
distributed by the host app as per-sender keys and injected with
``RTCSession/setFrameEncryptionKey(_:index:for:)``.

## Entry points (conceptual)

- **Outbound / negotiated start:** `createGroupCall`, ``createSFUIdentity``, ``groupCallNegotiation``, then media bootstrap when identities and transport are ready.
- **Inbound control messages:** your transport decodes wire payloads into ``RTCGroupCall/ControlMessage`` and calls ``RTCSession/handleControlMessage(_:)`` for answers, offers, candidates, and roster messages.
- **Ratchet-encrypted channel:** the `TaskProcessor` actor performs encrypt/decrypt; decrypted payloads are dispatched into `RTCSession`’s internal stream handler (see `TaskProcessor` + `RTCSession+GroupCall` in source).

> Warning: group/conference SFU renegotiation is explicit and server-driven. Do not turn a generic
> WebRTC `negotiationNeeded` / `shouldNegotiate` callback into another group/conference offer.
> The initial client offer is sent by media bootstrap, local screen-share changes call
> ``RTCSession/sendGroupCallOffer(_:)`` directly, and remote/new-track updates arrive as SFU
> offers. Extra client offers during rejoin create SDP glare and can reflect already-forwarded
> remote tracks back to the SFU as fake local source tracks.

## Flags and post-cipher handshake

- Control-plane packets use ``PacketFlag`` (e.g. ``PacketFlag/offer``, ``PacketFlag/answer``, ``PacketFlag/candidate``, ``PacketFlag/handshakeComplete``). The **`.handshakeComplete`** case carries an updated `Call` / identity payload **after** the initial cipher exchange—it is not a renegotiation offer. Host routing must not treat it as a second remote “offer” for 1:1.
- The SFU or transport may **deliver duplicate** `.handshakeComplete` ciphertexts; PQSRTC deduplicates identical ratchet material per connection in ``TaskProcessor`` to avoid a second decrypt after the ratchet has advanced (which would fail with a core-crypto error).
- The host transport may also deliver duplicate `call_cipher` messages. PQSRTC ignores exact
  duplicates, but a refreshed `call_cipher` with different ciphertext is meaningful and must be
  processed as a fresh media-ratchet bootstrap. See <doc:OneToOneSfuFrameE2EE>.
- Group/conference sender-key envelopes may travel over the same host message flag used for
  `call_cipher`, but they are not pairwise media-ratchet ciphertexts. If the metadata contains an
  app sender-key envelope such as `conferenceFrameKey`, route it to
  ``RTCSession/setFrameEncryptionKey(_:index:for:)`` using the sender participant id, not to
  ``RTCSession/finishCryptoSessionCreation(ciphertext:call:)``.

## Media owner reconciliation

For Apple SFU media, receiver callbacks can arrive before the SFU advertises the stable publisher
id. PQSRTC reconciles camera, audio, and screen-share owners from SDP after
`setRemoteDescription`. This keeps receiver FrameCryptors bound to the remote sender id instead of
UUID placeholders or room ids. If only video decrypts and audio sounds scrambled, inspect the
receiver logs for a missing `Created receiver FrameCryptor kind=audio participantId=<sender>` line.

## Server contract

- The **SwiftSFU** process defines IRC-backed SFU behavior, room routing, and relay rules. See the SwiftSFU documentation catalog in the `swift-sfu` package for environment variables, control-plane behavior, and client-facing expectations.
- The **Nudge** / NeedleTail app bridges IRC SFU messages into PQSRTC; your host must key rooms consistently (`sharedCommunicationId`, `#` channel form, and normalized connection ids) as the SDK expects.
- Roster updates should represent current room membership. PQSRTC uses them as an additional cleanup
  signal for departed participants' receiver tracks and FrameCryptors.

## See also

- <doc:GroupConferenceRemoteVideo> — group/conference remote **video tile** architecture (Apple + Android)
- <doc:HostAppCallKitAndSFU> for **iOS CallKit** ordering with SFU
- <doc:OneToOneSfuFrameE2EE> for `call_cipher` and 1:1 SFU frame-key agreement
- <doc:GroupSfuFrameE2EE> for group/conference sender keys and app-injected frame keys
- <doc:SfuRemoteVideoFrameE2EE> for **remote video** and per-participant **frame E2EE** (SFU)
- <doc:Getting-Started>
- ``RTCSession``
- ``RTCGroupCall``
