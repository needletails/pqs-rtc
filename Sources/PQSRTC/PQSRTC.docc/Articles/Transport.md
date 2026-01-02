# Transport

`PQSRTC` is transport-agnostic. The SDK never opens sockets, talks to your backend, or defines a concrete signaling protocol.

Instead, you implement ``RTCTransportEvents`` and route inbound messages back into the SDK.

## Responsibilities

### Your app / backend

- Decide how peers find each other (push, websocket, APNs/FCM, etc.)
- Serialize messages (JSON, protobuf, msgpack, …)
- Route messages to the correct call instance (typically by ``Call/sharedCommunicationId``)
- Route opaque ciphertext blobs for:
  - 1:1 Double Ratchet handshake/ratcheting
  - (optional) group sender-key distribution

### The SDK

- Produces/consumes SDP and ICE
- Manages PeerConnections
- Manages frame-level encryption key provider and FrameCryptors

## Outbound callbacks (`RTCTransportEvents`)

Your implementation receives outbound intents from the SDK:

- ``RTCTransportEvents/sendOffer(call:)``
- ``RTCTransportEvents/sendAnswer(call:metadata:)`` (1:1)
- ``RTCTransportEvents/sendCandidate(_:call:)``
- ``RTCTransportEvents/sendCiphertext(recipient:connectionId:ciphertext:call:)``
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
  - offer → ``RTCSession/handleOffer(call:sdp:metadata:)``
  - answer → ``RTCSession/handleAnswer(call:sdp:)``

### ICE candidates

Serialize ``IceCandidate`` and route inbound via:

- ``RTCSession/handleCandidate(call:candidate:)`` (1:1)
- or for SFU group calls, via ``RTCGroupCall/handleControlMessage(_:)`` with `.sfuCandidate`.

### Ciphertext

Ciphertext is opaque to your transport.

You must route it:

- **1:1**: into the call setup flow (see <doc:One-to-One-Calls>)
- **Group** (sender-key distribution): into ``RTCGroupCall/handleCiphertextFromParticipant(fromParticipantId:connectionId:ciphertext:)``

## Joining an SFU group call

For SFU signaling, you typically treat the SFU as a special “recipient”:

- `to: "sfu"` (or any constant/identifier you choose)
- deliver inbound SFU answer/candidates into ``RTCGroupCall`` using ``RTCGroupCall/handleControlMessage(_:)``.

See <doc:Group-Calls>.
