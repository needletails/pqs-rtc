# One-to-One Calls

This article describes the 1:1 call flow using ``RTCSession``.

The SDK exposes two layers:

- **Signaling primitives**: ``RTCSession/handleOffer(call:sdp:metadata:)``, ``RTCSession/handleAnswer(call:sdp:)``, ``RTCSession/handleCandidate(call:candidate:)``
- **E2EE handshake**: an opaque ciphertext exchange over your transport (``RTCTransportEvents/sendCiphertext(recipient:connectionId:ciphertext:call:)``)

> Note: 1:1 calls can be used with either ``RTCFrameEncryptionKeyMode/shared`` or ``RTCFrameEncryptionKeyMode/perParticipant``. Group calls should use `perParticipant`.

## High-level sequence

1) Caller and callee exchange identity props (``SessionIdentity.UnwrappedProps``) via your control plane.
2) The callee sends a ratchet ciphertext to the caller (opaque to your transport).
3) The caller decides whether to answer (accept/reject) and then sends the SDP offer.
4) Standard SDP+ICE proceeds.

## Caller flow (outbound)

### 1) Prepare crypto session

The caller must have the callee’s identity props available on the call (typically in `call.identityProps`).

```swift
// call.identityProps must be set to the remote participant's identity props.
try await session.createCryptoSession(with: call)
```

### 2) Receive callee ciphertext, decide to answer, then send offer

When your transport receives a ciphertext blob from the callee, call:

```swift
// Option A: accept
session.setCanAnswer(true)

let updatedCall = try await session.finishCryptoSessionCreation(
  recipient: remoteSecretName,
  ciphertext: ciphertext,
  call: call
)
// finishCryptoSessionCreation will send the SDP offer via RTCTransportEvents.sendOffer.
```

To reject:

```swift
session.setCanAnswer(false)
_ = try? await session.finishCryptoSessionCreation(
  recipient: remoteSecretName,
  ciphertext: ciphertext,
  call: call
)
```

## Callee flow (inbound)

### 1) Receive the SDP offer

When your transport receives an SDP offer, call:

```swift
let processedCall = try await session.handleOffer(
  call: call,
  sdp: offer,
  metadata: metadata
)

// `handleOffer` will send an SDP answer via RTCTransportEvents.sendAnswer.
```

### 2) Exchange ICE candidates

Both sides deliver inbound ICE via:

```swift
try await session.handleCandidate(call: call, candidate: candidate)
```

## Delivering an SDP answer to the caller

When the caller receives an SDP answer:

```swift
try await session.handleAnswer(call: call, sdp: answer)
```

## Troubleshooting

- If the caller never sends an offer after `finishCryptoSessionCreation`, check that you set `setCanAnswer(true)` (or `setCallAnswerState(_:for:)`).
- If you see “RTCTransportEvents delegate not set”, ensure you passed a transport delegate into ``RTCSession/init(iceServers:username:password:logger:ratchetSalt:frameEncryptionKeyMode:delegate:)`` or called ``RTCSession/setDelegate(_:)``.
- If audio/video decrypts as `missingKey`, ensure both sides are consistently using the same participant IDs (see <doc:End-to-End-Encryption>).
