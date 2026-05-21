# Transport

`PQSRTC` is transport-agnostic. The SDK never opens sockets, talks to your backend, or defines a concrete signaling protocol.

Instead, you implement ``RTCTransportEvents`` and route inbound messages back into the SDK.

## Responsibilities

### Your app / backend

- Decide how peers find each other (push, websocket, APNs/FCM, etc.)
- Serialize messages (JSON, protobuf, msgpack, …)
- Route messages to the correct call instance (typically by ``Call/sharedCommunicationId``)
- Route opaque 1:1 `call_cipher` blobs for Double Ratchet handshake/ratcheting.
- For encrypted group media, distribute per-sender frame keys over an encrypted app-defined route
  and inject them with ``RTCSession/setFrameEncryptionKey(_:index:for:)``.

### The SDK

- Produces/consumes SDP and ICE
- Manages PeerConnections
- Manages frame-level encryption key provider and FrameCryptors

## Outbound callbacks (`RTCTransportEvents`)

Your implementation receives outbound intents from the SDK:

- ``RTCTransportEvents/sendCiphertext(recipient:connectionId:ciphertext:call:)``
- ``RTCTransportEvents/sendOneToOneMessage(_:recipient:)`` (1:1 encrypted signaling: offer/answer/candidate via `packet.flag`)
- ``RTCTransportEvents/sendSfuMessage(_:call:)`` (SFU group-call encrypted signaling: offer/answer/candidate via `packet.flag`)
- ``RTCTransportEvents/sendStartCall(_:)``
- ``RTCTransportEvents/sendCallAnswered(_:)``
- ``RTCTransportEvents/sendCallAnsweredAuxDevice(_:)``
- ``RTCTransportEvents/didEnd(call:endState:)``

A few important routing rules:

- `call.sharedCommunicationId` is the primary call routing key.
- `recipient` is an app-level identifier (often a `secretName`).
- `connectionId` is a stable string that must be round-tripped back when delivering ciphertext.

## Suggested message envelope

This SDK doesn’t require a specific schema, but in practice you’ll want a small envelope so your transport can route and decode messages.

Example (JSON-ish):

```json
{
  "callId": "<Call.sharedCommunicationId>",
  "from": "alice",
  "to": "bob",
  "type": "sdpOffer|sdpAnswer|iceCandidate|ciphertext|groupControl",
  "payload": { }
}
```

### SDP offer/answer

When you send/receive SDP, you’ll usually serialize ``SessionDescription``.

- For 1:1 offers/answers, route inbound:
  - offer → ``RTCSession/handleOffer(call:sdp:metadata:)`` (SDK will emit `sendOneToOneMessage(..., flag: .answer, ...)`)
  - answer → ``RTCSession/handleAnswer(call:sdp:)``

### ICE candidates

Serialize ``IceCandidate`` and route inbound via:

- ``RTCSession/handleCandidate(call:candidate:)`` (1:1)
- or for SFU group calls, via ``RTCGroupCall/handleControlMessage(_:)`` with `.sfuCandidate`.

### Ciphertext

Ciphertext is opaque to your transport.

For 1:1 calls, route it into the call setup flow (see <doc:One-to-One-Calls>).

For group media, sender-key envelopes are host-defined. They should carry the room id, sender
participant id, key index, and key bytes, then the receiver should call
``RTCSession/setFrameEncryptionKey(_:index:for:)`` for that sender id. Do not deliver group sender
keys into the pairwise `call_cipher` receive path.

### 1:1 SFU call_cipher

For 1:1 calls relayed through an SFU room, ``RTCTransportEvents/sendCiphertext(recipient:connectionId:ciphertext:call:)``
is also the `call_cipher` media-ratchet identity exchange.

The transport contract is:

- Preserve `ciphertext` exactly.
- Preserve and deliver `connectionId` back to the peer's receive path.
- Preserve the encoded ``Call``. Its ``Call/frameIdentityProps`` and
  ``Call/signalingIdentityProps`` are part of the key agreement.
- Route to the `recipient` peer. Do not invent a second target field for call cipher routing.

The SFU room id is a transport route, not the frame-key participant id. See
<doc:OneToOneSfuFrameE2EE> before changing this path.

### Group sender-key transport

For channel-backed group calls and `conf-` rooms, media keys are not derived from pairwise
`call_cipher`. Your application distributes a sender key for each publisher. A typical envelope is:

```json
{
  "type": "groupSenderFrameKey",
  "roomId": "#team-room",
  "senderSecretName": "alice",
  "keyIndex": 0,
  "frameKey": "<opaque bytes>"
}
```

On receive:

```swift
await session.setFrameEncryptionKey(frameKey, index: keyIndex, for: senderSecretName)
```

See <doc:GroupSfuFrameE2EE>.

## Joining an SFU group call

For SFU signaling, you typically treat the SFU as a special “recipient”.
You do **not** need IRC tags for SFU signaling: the SDK emits/consumes a `RatchetMessagePacket`
that already includes a `flag` describing the message kind (offer/answer/candidate).

- `to: "sfu"` (or any constant/identifier you choose)
- deliver inbound SFU answer/candidates into ``RTCGroupCall`` using ``RTCGroupCall/handleControlMessage(_:)``.

See <doc:Group-Calls>.
