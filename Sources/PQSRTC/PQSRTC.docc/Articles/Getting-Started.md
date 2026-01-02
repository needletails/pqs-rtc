# Getting Started

This article covers the practical integration points for using `PQSRTC` in a production app:

- How to implement the transport layer
- How to instantiate ``RTCSession``
- How to route inbound signaling and ciphertext
- How to choose between 1:1 and SFU group calls

If you’re starting with group calls, also read <doc:Group-Calls>.

## Before you start

You need:

- A signaling/control plane (your backend or P2P messaging layer) capable of routing:
  - SDP offers/answers
  - ICE candidates
  - Opaque ciphertext blobs
- Stable identifiers to route messages to a specific call instance, typically ``Call/sharedCommunicationId``.

## 1) Implement the transport

Your app implements ``RTCTransportEvents``. Think of these as “outbound intents” from the SDK.

```swift
import Foundation
import PQSRTC

struct MyTransport: RTCTransportEvents {
  func sendOffer(call: Call) async throws {
    // Send call's SDP offer to your peer or SFU.
    // The easiest routing key is call.sharedCommunicationId.
  }

  func sendAnswer(call: Call, metadata: PQSRTC.SDPNegotiationMetadata) async throws {
    // 1:1 only.
    // Send the SDP answer to the offerer along with negotiation metadata.
  }

  func sendCandidate(_ candidate: IceCandidate, call: Call) async throws {
    // Send ICE candidate to your peer/SFU.
  }

  func sendCiphertext(
    recipient: String,
    connectionId: String,
    ciphertext: Data,
    call: Call
  ) async throws {
    // Deliver opaque ciphertext to a specific recipient.
    // Used for 1:1 DoubleRatchet and (optionally) group sender-key distribution.
    // - `recipient` is an app-level identifier (e.g. secretName).
    // - `connectionId` is a stable string you should round-trip back on receive.
  }

  func didEnd(call: Call, endState: CallStateMachine.EndState) async throws {
    // Inform your backend/UI.
  }
}
```

> Recommended next read: <doc:Transport> (message routing + practical payload shapes).

## 2) Create a session

Create one ``RTCSession`` per “client runtime” (app session) and reuse it across calls.

```swift
import PQSRTC

let session = RTCSession(
  iceServers: ["stun:stun.l.google.com:19302"],
  username: "",
  password: "",
  frameEncryptionKeyMode: .perParticipant,
  delegate: MyTransport()
)
```

### Choosing `frameEncryptionKeyMode`

- Use ``RTCFrameEncryptionKeyMode/perParticipant`` for SFU group calls.
- For 1:1 calls you can use either:
  - ``RTCFrameEncryptionKeyMode/shared`` (simpler), or
  - ``RTCFrameEncryptionKeyMode/perParticipant`` (more consistent with group calls).

## 3) Route inbound messages

Your app receives messages from the network and calls into the SDK.

### Inbound signaling (SDP / ICE)

For 1:1 calls:

- Offerer receives an answer → ``RTCSession/handleAnswer(call:sdp:)``
- Answerer receives an offer → ``RTCSession/handleOffer(call:sdp:metadata:)``
- Both sides receive ICE candidates → ``RTCSession/handleCandidate(call:candidate:)``

For SFU group calls, you typically route SFU answer/candidates into ``RTCGroupCall``:

```swift
try await groupCall.handleControlMessage(.sfuAnswer(answerSdp))
try await groupCall.handleControlMessage(.sfuCandidate(candidate))
```

### Inbound ciphertext

Ciphertext is intentionally opaque to your transport. You only need to route it to the right call.

- For group calls, if you use sender-key distribution over the transport, call:
  ``RTCGroupCall/handleCiphertextFromParticipant(fromParticipantId:connectionId:ciphertext:)``
- For 1:1 calls, you typically route ciphertext into the ongoing call setup (see <doc:One-to-One-Calls>).

## 4) Choose a call style

### SFU group calls

Create a group call wrapper and join:

```swift
let groupCall = session.createGroupCall(call: call, sfuRecipientId: "sfu")
try await groupCall.join()

Task {
  for await event in await groupCall.events() {
    // Update your UI or state machine.
    // .remoteTrackAdded(participantId:kind:trackId:)
  }
}
```

Next: <doc:Group-Calls>.

### 1:1 calls

1:1 calls are driven by SDP+ICE methods on ``RTCSession``.

Next: <doc:One-to-One-Calls>.
