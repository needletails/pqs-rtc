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

## Group calls: two keying models

### A) Control-plane injected keys

Your app/server distributes media keys out-of-band and injects them using:

- ``RTCGroupCall/setFrameEncryptionKey(_:index:for:)``

Important:

- `participantId` refers to the **sender / track owner**.
- `index` is the key ring index (rotations can be modeled as incrementing indices).

### B) Sender keys

This follows the sender-key distribution model:

- Each sender generates a per-sender media key.
- The sender encrypts that key to each other member using pairwise Double Ratchet.
- The SFU never sees media keys.

In this SDK:

- Sender rotates and sends:
  - ``RTCGroupCall/rotateAndSendLocalSenderKeyForCurrentParticipants()``
- Receiver applies inbound sender keys after decrypting:
  - ``RTCGroupCall/handleCiphertextFromParticipant(fromParticipantId:connectionId:ciphertext:)``

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

- `internalError`: typically indicates platform WebRTC errors or unexpected cryptor state.
  - Confirm you are setting keys *before* expecting decrypt.
  - For group calls, ensure you inject keys for each active sender.
