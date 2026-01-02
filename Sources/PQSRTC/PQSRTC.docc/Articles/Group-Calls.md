# Group Calls (SFU)

PQSRTC supports **SFU-style group calls** (one `RTCPeerConnection` to an SFU, multiple inbound tracks under Unified Plan) and **frame-level E2EE**.

This SDK is intentionally transport-agnostic: your app provides signaling/control-plane networking via ``RTCTransportEvents``.

If you haven’t set up your servers yet, start with <doc:Connecting-to-Servers>.

## Concepts

### ``RTCSession``

``RTCSession`` is the core actor that owns WebRTC state, call state, and E2EE primitives.

You provide an app-defined transport (``RTCTransportEvents``) for exchanging offer/answer/candidates (and optional ciphertext).

### ``RTCGroupCall``

``RTCGroupCall`` is a small SFU group-call facade over ``RTCSession``.

- `join()` starts the SFU call and triggers ``RTCTransportEvents/sendOffer(call:)``.
- `handleControlMessage(.sfuAnswer(_))` / `handleControlMessage(.sfuCandidate(_))` apply SFU signaling.
- `handleControlMessage(.participants(_))` / `handleControlMessage(.participantDemuxId(participantId:demuxId:))` apply roster updates.
- `handleControlMessage(.frameKey(participantId:index:key:))` injects frame keys (control-plane keying).
- `rotateAndSendLocalSenderKeyForCurrentParticipants()` distributes sender keys (true group E2EE).

### Participant identifiers

The SDK needs a stable `participantId` for each sender so that:

- your app can map tracks to UI tiles, and
- frame-level keys can be applied to the correct sender/track owner.

Default convention: `participantId == streamIds.first` (from the WebRTC receiver event).

If your SFU uses a different convention, configure a resolver:

```swift
session.setRemoteParticipantIdResolver { streamIds, trackId, trackKind in
  // Return the participantId for this track.
  streamIds.first
}
```

## Basic flow (end-to-end)

### 1) Implement the transport

You implement ``RTCTransportEvents`` to send signaling to your backend/SFU.

```swift
import PQSRTC

struct MyTransport: RTCTransportEvents {
  func sendOffer(call: Call) async throws {
    // Send `call.sdp` (and any IDs in Call) to your signaling service.
  }

  func sendAnswer(call: Call, metadata: PQSRTC.SDPNegotiationMetadata) async throws {
    // 1:1 only (not used for SFU group calls).
  }

  func sendCandidate(_ candidate: IceCandidate, call: Call) async throws {
    // Send ICE candidates to your signaling service.
  }

  func sendCiphertext(recipient: String, connectionId: String, ciphertext: Data, call: Call) async throws {
    // Opaque ciphertext transport.
    // Used for 1:1 Double Ratchet handshake payloads and (optionally) group sender-key distribution.
  }

  func didEnd(call: Call, endState: CallStateMachine.EndState) async throws {
    // Inform your backend/UI.
  }
}
```

### 2) Create the session

For SFU group calls, prefer per-participant keying.

```swift
let session = RTCSession(
  iceServers: ["stun:stun.l.google.com:19302"],
  username: "",
  password: "",
  frameEncryptionKeyMode: .perParticipant,
  delegate: MyTransport()
)
```

### 3) Create a group call handle

You provide a ``Call`` (your model object) and an `sfuRecipientId`.

`sfuRecipientId` is a routing identity used by your transport. For SFU calls it represents “the SFU endpoint”, not a user.

```swift
let groupCall = await session.createGroupCall(call: call, sfuRecipientId: "sfu")
```

### 4) Join and observe events

```swift
Task {
  for await event in await groupCall.events() {
    switch event {
    case .stateChanged(let state):
      print("group call state=\(state)")

    case .participantsUpdated(let participants):
      print("participants=\(participants)")

    case .remoteTrackAdded(let participantId, let kind, let trackId):
      print("remote track: \(participantId) kind=\(kind) trackId=\(trackId)")
    }
  }
}

try await groupCall.join()
```

At `join()`, the SDK will:

- create a PeerConnection intended to connect to your SFU,
- create an offer,
- call your transport: ``RTCTransportEvents/sendOffer(call:)``.

### 5) Feed SFU signaling back into the SDK

When your app receives the SFU answer/candidates from your signaling service:

```swift
try await groupCall.handleControlMessage(.sfuAnswer(answerSessionDescription))
try await groupCall.handleControlMessage(.sfuCandidate(remoteCandidate))
```

## Roster + demux updates

Your control plane should tell the client who is in the call, and (optionally) any SFU demux ids.

```swift
await groupCall.handleControlMessage(
  .participants([
    .init(id: "alice"),
    .init(id: "bob")
  ])
)

await groupCall.handleControlMessage(
  .participantDemuxId(participantId: "alice", demuxId: 1234)
)
```

## E2EE keying models

You have two supported keying models for group calls.

### 1) Control-plane injected keys

Your app/server distributes frame keys out-of-band and injects them.

Important rule: the `participantId` used here must identify the **track owner / sender id**.

```swift
await groupCall.handleControlMessage(
  .frameKey(participantId: "alice", index: 0, key: aliceMediaKey)
)
```

### 2) Sender keys over Double Ratchet (true group E2EE)

In this model:

- Each sender encrypts outbound media with a per-sender key.
- That sender key is distributed to each group member using pairwise Double Ratchet encrypted messages.
- The SFU forwards encrypted RTP frames and never sees media keys.

Workflow:

1) Provide each participant’s ratchet identity props to the group call.

```swift
try await groupCall.handleControlMessage(.participantIdentity(identity))
```

2) Rotate + send a new local sender key.

```swift
try await groupCall.rotateAndSendLocalSenderKeyForCurrentParticipants()
```

3) When you receive ciphertext from another participant, deliver it to the group call.

```swift
try await groupCall.handleCiphertextFromParticipant(
  fromParticipantId: fromId,
  connectionId: connectionId,
  ciphertext: ciphertext
)
```

See also <doc:End-to-End-Encryption>.
