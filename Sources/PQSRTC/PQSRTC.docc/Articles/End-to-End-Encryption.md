# End-to-End Encryption (E2EE)

`PQSRTC` encrypts *media frames* end-to-end using WebRTC frame encryption primitives (FrameCryptor + KeyProvider). This is independent of SDP/ICE signaling security.

## Two layers of “encryption”

### 1) Transport encryption

Your signaling channel (websocket/TLS, HTTPS, etc.) may be encrypted in transit, but your server can still see plaintext media if it terminates encryption.

### 2) Frame-level E2EE (this SDK)

With frame-level E2EE:

- Audio/video frames are encrypted on the sender before leaving the device.
- Frames are decrypted only on receiving devices that have the correct media keys.
- SFUs and TURN servers forward encrypted frames but cannot decrypt.

## Key application model: `RTCFrameEncryptionKeyMode`

The SDK supports two ways to apply media keys:

- ``RTCFrameEncryptionKeyMode/shared``
  - One shared key ring.
  - Simplest configuration.
  - Best suited for 1:1 calls.

- ``RTCFrameEncryptionKeyMode/perParticipant``
  - Keys are applied per `participantId`.
  - Required for SFU group calls, where multiple senders’ frames are interleaved.

## The critical rule: participant IDs must match

For frame-level E2EE to work, the sender and receiver must use the same `participantId` to look up keys.

- **Outbound media** is configured with the *local sender’s* participant ID.
- **Inbound media** must be configured with the *remote track owner’s* participant ID.

In group calls, that remote track owner ID is what your roster/control plane calls the participant.

For 1:1 calls relayed through an SFU, the remote track owner is still the peer, even though the
PeerConnection and transport route may be keyed by an ephemeral room id. The `call_cipher` exchange
is what aligns the two peers' frame identities and media-ratchet sessions. See
<doc:OneToOneSfuFrameE2EE>.

## Group calls: per-sender frame keys

Encrypted SFU group calls use sender keys injected by the host app:

- Each sender generates a per-sender media key.
- The host app encrypts and sends that sender key to each other group member.
- Each receiver installs the key with ``RTCSession/setFrameEncryptionKey(_:index:for:)`` under the
  sender / track-owner participant id.
- The SFU forwards encrypted RTP and never sees media keys.

Important:

- `participantId` refers to the **sender / track owner**.
- `index` is the FrameCryptor key-ring index.
- Pairwise `call_cipher` is not the group media keying primitive. It is reserved for 1:1 media.

See <doc:GroupSfuFrameE2EE>.

## Participant ID mapping in SFU calls

When an SFU forwards multiple inbound tracks, the SDK needs a stable `participantId` for each track.

By default, the SDK uses the first WebRTC `streamId` associated with the receiver.

If your SFU uses another convention, set a resolver:

```swift
session.setRemoteParticipantIdResolver { streamIds, trackId, trackKind in
  // Return the track owner's participantId.
  streamIds.first
}
```

## Debugging: common symptoms

- `missingKey`: receiver cryptor is running but no key exists for the participantId/index.
  - Verify you applied the key with the correct participantId.
  - Verify your resolver returns the same participantId your control plane uses.
  - For 1:1 SFU, verify the inbound `call_cipher` ``Call/frameIdentityProps`` belongs to the
    remote peer and that the receive key was installed under the remote track owner, not the room id.
  - For group SFU, verify the app injected a sender key for the remote sender id, not the room id.

- `internalError`: typically indicates platform WebRTC errors or unexpected cryptor state.
  - Confirm you are setting keys *before* expecting decrypt.
  - For group calls, ensure you inject keys for each active sender.
