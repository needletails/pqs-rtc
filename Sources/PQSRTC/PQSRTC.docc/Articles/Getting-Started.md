# Getting Started

Practical integration points for `PQSRTC`:

- Implement the transport
- Construct ``RTCSession`` (`async`)
- Route inbound signaling and ciphertext
- Choose 1:1 vs SFU group/conference

If you are starting with group calls, also read <doc:Group-Calls> and <doc:Architecture>.

## Before you start

You need:

- A signaling/control plane that can route SDP, ICE, and opaque ciphertext
- Stable identifiers, typically ``Call/sharedCommunicationId`` plus an explicit SFU wire id when the call is SFU-relayed
- For NeedleTails production: Nudge Server (auth + messaging) and SwiftSFU (rooms + RTP). See <doc:Connecting-to-Servers>.

## 1) Implement the transport

Your app implements ``RTCTransportEvents``. These are outbound intents from the SDK.

```swift
import Foundation
import PQSRTC

struct MyTransport: RTCTransportEvents {
  func sendStartCall(_ call: Call) async throws {
    // 1:1: start_call so the callee can receive VoIP / incoming UI.
  }

  func sendOneToOneMessage(_ packet: RatchetMessagePacket, recipient: Call.Participant) async throws {
    // 1:1 encrypted signaling. Use packet.flag for offer/answer/candidate.
  }

  func sendSfuMessage(_ packet: RatchetMessagePacket, call: Call) async throws {
    // SFU encrypted signaling. Use packet.flag for offer/answer/candidate/handshakeComplete.
  }

  func sendCiphertext(
    recipient: String,
    connectionId: String,
    ciphertext: Data,
    call: Call
  ) async throws {
    // Opaque 1:1 Double Ratchet / call_cipher bytes.
    // Round-trip recipient, connectionId, ciphertext, and Call identity props unchanged.
  }

  func didEnd(call: Call, endState: CallStateMachine.EndState) async throws {
    // Inform your backend / UI.
  }
}
```

Next: <doc:Transport>.

## 2) Create a session

Create one ``RTCSession`` per app runtime and reuse it. Init is `async`. Frame-encryption mode is on ``RTCSession/CryptorConfiguration`` (default `.perParticipant`).

```swift
import PQSRTC

let session = await RTCSession(
  iceServers: ["stun:stun.l.google.com:19302"],
  username: "",
  password: "",
  cryptorConfig: .init(mode: .perParticipant),
  delegate: MyTransport()
)
```

### Choosing `CryptorConfiguration.mode`

- ``RTCFrameEncryptionKeyMode/perParticipant`` — required for SFU group/conference E2EE; also fine for 1:1.
- ``RTCFrameEncryptionKeyMode/shared`` — simplest 1:1 key ring.
- ``RTCFrameEncryptionKeyMode/none`` — FrameCryptor off (debugging or non-E2EE media).

ICE defaults to ``RTCIceTransportPolicyStrategy/allThenRelay(timeoutMilliseconds:)`` (4 seconds). Pass TURN REST username/password when your backend issues them.

On iOS inbound SFU, call ``RTCSession/setRequiresExternalAudioActivation(_:)`` before answering and ``RTCSession/markExternalAudioActivationComplete()`` from CallKit `didActivate`. See <doc:HostAppCallKitAndSFU>.

## 3) Route inbound messages

### 1:1 SDP / ICE

- Offer → ``RTCSession/handleOffer(call:sdp:metadata:)``
- Answer → ``RTCSession/handleAnswer(call:sdp:)``
- ICE → ``RTCSession/handleCandidate(call:candidate:)``

### SFU group / conference

Decode wire payloads into ``RTCGroupCall/ControlMessage`` and call **``RTCSession/handleControlMessage(_:)``** (not a method on ``RTCGroupCall``):

```swift
try await session.handleControlMessage(.sfuAnswer(answerPacket))
try await session.handleControlMessage(.sfuCandidate(candidatePacket))
try await session.handleControlMessage(.sfuOffer(offerPacket))
```

Roster cases take a ``RatchetMessagePacket``, not a raw participant array. After decrypt, you can also update the facade with ``RTCGroupCall/updateParticipants(_:)``.

### Ciphertext and frame keys

1:1 `call_cipher` stays opaque. Route it into the 1:1 setup path (<doc:One-to-One-Calls>, <doc:OneToOneSfuFrameE2EE>).

Group sender keys travel on your encrypted app route. Inject with ``RTCSession/setFrameEncryptionKey(_:index:for:)``. Do not feed group keys into `finishCryptoSessionCreation`. See <doc:GroupSfuFrameE2EE>.

## 4) Choose a call style

### SFU group / conference

Production join path:

```swift
try await session.groupCallNegotiation(call: call, sfuRecipientId: roomId)

if let groupCall = session.groupCallForRoom(roomId) {
  Task {
    for await event in await groupCall.events() {
      // .stateChanged, .participantsUpdated, .remoteTrackAdded(...)
    }
  }
}
```

`createGroupCall(call:sfuRecipientId:localIdentity:)` is the lower-level wrapper. Prefer `groupCallNegotiation`, which generates or loads ``ConnectionLocalIdentity`` and registers the room.

Media is not up at `RTCGroupCall.join()`. The PeerConnection and initial offer run after SFU registration via ``beginGroupCallMediaAfterSfuRegistrationIfNeeded(sfuRecipientId:)``.

Next: <doc:Group-Calls>.

### 1:1 calls

Driven by SDP + ICE (and `call_cipher` when E2EE is on) on ``RTCSession``.

Next: <doc:One-to-One-Calls>.

## Platform notes

- **Apple:** iOS 18+ / macOS 15+, Swift 6.3, WebRTC via the package’s Specs binary.
- **Android:** same Swift sources via Skip; min SDK is the host app’s.
- **Audio (iOS inbound SFU):** <doc:HostAppCallKitAndSFU> is mandatory before changing answer order.

### Next reads

- <doc:Architecture>
- <doc:HostAppCallKitAndSFU>
- <doc:SFUSignalingOverview>
- <doc:OneToOneSfuFrameE2EE>
- <doc:GroupSfuFrameE2EE>
- <doc:SfuRemoteVideoFrameE2EE>
- <doc:ScreenShare>
