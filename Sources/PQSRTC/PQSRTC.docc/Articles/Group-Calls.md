# Group Calls (SFU)

PQSRTC supports **SFU-style group calls**: one `RTCPeerConnection` to the SFU, multiple inbound tracks under Unified Plan, and optional frame-level E2EE.

The SDK is transport-agnostic. Your app provides ``RTCTransportEvents``. NeedleTails production SFU is SwiftSFU — see <doc:Connecting-to-Servers>.

## Concepts

### ``RTCSession``

Owns WebRTC state, call state, and E2EE primitives. Inbound SFU packets enter through ``RTCSession/handleControlMessage(_:)``.

### ``RTCGroupCall``

Per-room facade created by ``RTCSession/groupCallNegotiation(call:sfuRecipientId:)``.

- `join()` advances facade state only. Media starts after SFU registration via ``RTCSession/beginGroupCallMediaAfterSfuRegistrationIfNeeded(sfuRecipientId:)``.
- `events()` reports state, roster, and ``RTCGroupCall/Event/remoteTrackAdded(participantId:kind:trackId:)``.
- Use `updateParticipants` / `setDemuxId` for local roster views. Wire roster still arrives as encrypted packets on ``RTCSession/handleControlMessage(_:)``.

### Participant identifiers

Stable `participantId` values map tracks to UI tiles and FrameCryptor slots.

Default: first WebRTC `streamId`. Apple SFU often emits a UUID placeholder first; PQSRTC reconciles the owner from SDP `msid` after `setRemoteDescription`. Camera and audio for one sender must share the same id.

Override with ``RTCSession/setRemoteParticipantIdResolver(_:)`` if your SFU uses another convention.

## Basic flow

### 1) Transport

Implement ``RTCTransportEvents`` (`sendSfuMessage`, `sendCiphertext` for 1:1 only, lifecycle callbacks). See <doc:Getting-Started>.

### 2) Session

```swift
let session = await RTCSession(
  iceServers: iceServers,
  username: turnUser,
  password: turnPass,
  cryptorConfig: .init(mode: .perParticipant),
  delegate: MyTransport()
)
```

### 3) Negotiate / register

`sfuRecipientId` is the SFU room route (channel / `conf-` id), not a user.

```swift
try await session.groupCallNegotiation(call: call, sfuRecipientId: roomId)
```

There is also `join(sender:participants:sfuRecipientId:)` as a compatibility wrapper that builds the ``Call`` for you.

After the SFU acknowledges registration and identity props exist, the session creates the PeerConnection and sends an encrypted offer through ``RTCTransportEvents/sendSfuMessage(_:call:)`` (`packet.flag == .offer`).

### 4) Feed SFU signaling into the session

```swift
try await session.handleControlMessage(.sfuAnswer(answerPacket))
try await session.handleControlMessage(.sfuCandidate(candidatePacket))
try await session.handleControlMessage(.sfuOffer(renegotiationOfferPacket))
try await session.handleControlMessage(.participants(rosterPacket))
try await session.handleControlMessage(.participantDemuxId(demuxPacket))
```

Every case carries a ``RatchetMessagePacket``, not raw SDP strings or id arrays.

### 5) Observe tracks

```swift
if let groupCall = session.groupCallForRoom(roomId) {
  for await event in await groupCall.events() {
    if case .remoteTrackAdded(let participantId, let kind, let trackId) = event {
      // Attach UI / inject sender keys for that participantId
    }
  }
}
```

## Roster

Send the full current roster when possible. If the roster removes `alice`, the SDK prunes `alice`’s camera, audio, screen, and receiver FrameCryptors. Do not send a transient empty roster during reconnect unless everyone has left — an empty roster is ignored as non-authoritative cleanup.

After you install a remote sender key, tell the SFU that this receiver is ready for that source:

```swift
try await session.sendSfuGroupMediaReady(
  sourceParticipantId: remoteSenderId,
  roomId: roomId,
  call: call
)
```

Otherwise encrypted RTP can arrive before the matching receiver key exists.

## E2EE

Per-sender keys, installed under the **track owner** id. See <doc:GroupSfuFrameE2EE>.

Do not derive group media keys from pairwise `call_cipher`.

## Screen share

Fixed mids: audio `0`, camera `1`, screen `2`. See <doc:ScreenShare>.

## Remote video rendering

<doc:GroupConferenceRemoteVideo> covers wrapper rotation, attach policy, and Apple vs Android settlement. Read it when implementing multiparty tiles—not only when debugging frozen frames.

## Related

- <doc:Architecture>
- <doc:SFUSignalingOverview>
- <doc:SfuRemoteVideoFrameE2EE>
