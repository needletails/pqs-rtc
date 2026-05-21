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

- `join()` starts the SFU call flow; after SFU identity negotiation, PQSRTC emits an encrypted
  offer via ``RTCTransportEvents/sendSfuMessage(_:call:)``.
- `handleControlMessage(.sfuAnswer(_))` / `handleControlMessage(.sfuCandidate(_))` apply SFU signaling.
- `handleControlMessage(.participants(_))` / `handleControlMessage(.participantDemuxId(_))` apply roster updates.
  Participant roster updates are also cleanup signals: when a stable participant leaves, PQSRTC
  removes that participant's stored receiver tracks and FrameCryptors.
- `events()` reports stable participant/track owners so the host can inject per-sender frame keys with
  ``RTCSession/setFrameEncryptionKey(_:index:for:)``.

### Participant identifiers

The SDK needs a stable `participantId` for each sender so that:

- your app can map tracks to UI tiles, and
- frame-level keys can be applied to the correct sender/track owner.

Default convention: `participantId == streamIds.first` (from the WebRTC receiver event).

For Apple SFU calls, the first receiver callback can contain a UUID-like placeholder. PQSRTC
reconciles the stable owner later from SDP `msid` lines after `setRemoteDescription`. This applies
to camera and audio: both receivers for a sender must resolve to the same stable `participantId`
before encrypted media can decode correctly.

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

  func sendSfuMessage(_ packet: RatchetMessagePacket, call: Call) async throws {
    // Group-call (SFU): forward the encoded packet to your SFU/signaling service.
    // Use `packet.flag` to distinguish offer/answer/candidate.
  }

  func sendCiphertext(recipient: String, connectionId: String, ciphertext: Data, call: Call) async throws {
    // Opaque ciphertext transport.
    // Used for 1:1 Double Ratchet / call_cipher payloads.
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
Send the full current roster when possible. If the roster removes `alice`, the SDK prunes `alice`'s
camera, audio, screen-share receiver maps, and receiver FrameCryptors. Avoid sending a transient
empty roster during reconnect unless everyone has really left, because an empty roster is ignored as
non-authoritative cleanup input.

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

## E2EE keying model

Encrypted group media uses application-injected **per-sender frame keys**.

The important rule: the `participantId` used with
``RTCSession/setFrameEncryptionKey(_:index:for:)`` must identify the **track owner / sender id**.

Local sender setup:

```swift
let localSenderId = call.sender.secretName
let localFrameKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) })

await session.setFrameEncryptionKey(localFrameKey, index: 0, for: localSenderId)
```

Remote sender setup after your host transport receives an encrypted sender-key envelope:

```swift
await session.setFrameEncryptionKey(
  remoteFrameKey,
  index: remoteKeyIndex,
  for: remoteSenderSecretName
)
```

Your app must distribute the local frame key to every current participant and to late joiners. A
minimal encrypted sender-key envelope contains:

- room id
- sender participant id
- frame key bytes
- key index

The envelope can be carried over an app-defined encrypted call-control route. Some host apps keep a
legacy metadata name such as `conferenceFrameKey`; that name is only wire compatibility. The SDK API
contract is still: call ``RTCSession/setFrameEncryptionKey(_:index:for:)`` with the sender's stable
participant id.

Do not derive group media frame keys from pairwise `call_cipher`. Pairwise `call_cipher` is the
1:1 media-ratchet identity exchange; group media has one outbound RTP stream per sender, so all
receivers of that sender need the same key bytes under the same sender id.

If encrypted video is correct but encrypted audio is garbled, check that the audio receiver was
reconciled to the same sender id as the video receiver and that a sender key exists for that id.

See <doc:GroupSfuFrameE2EE> and <doc:End-to-End-Encryption>.
