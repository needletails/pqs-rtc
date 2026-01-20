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
  func sendStartCall(_ call: Call) async throws {
    // 1:1 calls: Send start_call message to trigger VoIP notifications.
  }

  func sendOneToOneMessage(_ packet: RatchetMessagePacket, recipient: Call.Participant) async throws {
    // 1:1 calls: Send encrypted signaling packet.
    // Use `packet.flag` to distinguish offer/answer/candidate.
  }

  func sendSfuMessage(_ packet: RTCGroupE2EE.RatchetMessagePacket, call: Call) async throws {
    // Group-call (SFU): forward the encoded packet to your SFU/signaling service.
    // Use `packet.flag` to distinguish offer/answer/candidate.
    // Default implementation forwards through sendCiphertext(...).
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

After `join()`, your app should complete SFU identity negotiation (via your control plane) and
call ``RTCSession/createSFUIdentity(sfuRecipientId:call:)`` once it has the SFU’s identity props.
That call will:

- create a PeerConnection intended to connect to your SFU,
- create an offer,
- call your transport: ``RTCTransportEvents/sendSfuMessage(_:call:)`` with `packet.flag == .offer`.

### 5) Feed SFU signaling back into the SDK

When your app receives the SFU answer/candidates from your signaling service (encrypted packets):

```swift
try await groupCall.handleControlMessage(.sfuAnswer(answerPacket))
try await groupCall.handleControlMessage(.sfuCandidate(candidatePacket))
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
