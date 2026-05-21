# Group SFU frame E2EE and sender keys

This article documents the production contract for encrypted multi-party SFU media in PQSRTC.
It covers channel-backed group calls and `conf-` conference rooms.

Read this before changing:

- ``RTCSession/setFrameEncryptionKey(_:index:for:)``
- ``RTCSession/groupCallNegotiation(call:sfuRecipientId:)``
- ``RTCSession/beginGroupCallMediaAfterSfuRegistrationIfNeeded(sfuRecipientId:updatedCall:)``
- `RTCSession+RTCCipherTransport.swift`
- `RTCSession+PeerNotificationsHandler.swift`
- your host app's sender-key transport envelope

The short version: **group media uses per-sender frame keys.** Each sender publishes one outbound
RTP stream to the SFU, so every receiver must install the same sender key under that sender's
participant id. A pairwise `call_cipher` media ratchet derives a different key per recipient and
cannot represent one shared outbound group RTP stream.

## Room Shapes

PQSRTC has two SFU E2EE shapes:

| Shape | Media key source | FrameCryptor key owner |
| --- | --- | --- |
| True 1:1 SFU relay | Pairwise `call_cipher` media ratchet | local sender id / remote peer id |
| Channel group or `conf-` room | App-injected sender key | sender participant id |

True 1:1 SFU relay is documented separately in <doc:OneToOneSfuFrameE2EE>. Do not copy that
pairwise `call_cipher` keying model into group rooms.

## API Contract

Use ``RTCFrameEncryptionKeyMode/perParticipant`` for encrypted SFU group calls.

The host app is responsible for distributing sender keys over an encrypted application route. For
each local group media session:

1. Generate a fresh 32-byte local sender frame key.
2. Install it locally with ``RTCSession/setFrameEncryptionKey(_:index:for:)`` using the local
   participant id.
3. Encrypt and send that key to each remote participant with metadata that identifies:
   - the room id
   - the sender participant id
   - the frame key bytes
   - the key index
4. When a remote sender key arrives, install it with
   ``RTCSession/setFrameEncryptionKey(_:index:for:)`` using the remote sender participant id.
5. When new participants or stable remote track owners appear, send the local sender key to them.

> Warning: audio and video receiver FrameCryptors are independent, but they must resolve to the
> same publisher id and key index for a given sender. A common failure is "video works, audio is
> garbled": that means the video receiver was rebound to `alice`, while the audio receiver stayed on
> a UUID placeholder or a stale participant id. Do not recreate the PeerConnection to fix this; fix
> the receiver participant id and key installation.

Minimal host-side shape:

```swift
let senderId = localParticipant.secretName
let frameKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) })

await rtcSession.setFrameEncryptionKey(frameKey, index: 0, for: senderId)

// App-specific encrypted transport:
// send { roomId, senderId, keyIndex: 0, frameKey } to every remote participant.
```

Receiver:

```swift
await rtcSession.setFrameEncryptionKey(
  remoteFrameKey,
  index: remoteKeyIndex,
  for: remoteSenderSecretName
)
```

The index is the WebRTC FrameCryptor key-ring index. A sender may rotate by generating a new sender
key and incrementing the index, then distributing the new tuple to every current participant.

## Participant Id Rules

FrameCryptor keys are looked up by participant id:

- outbound sender FrameCryptors use the local participant id
- inbound receiver FrameCryptors use the remote track owner's participant id
- group/conference room ids are routing ids, not frame-key owners

For group media, install keys under stable participant ids such as `alice`, not:

- the SFU room id
- `#channel` / channel wire ids
- `conf-...`
- UUID-like placeholder stream ids
- labels with trailing `msid` underscores such as `alice_`

`RTCSession+PeerNotificationsHandler.swift` normalizes receiver labels so `alice_` maps to
`alice`, skips self-labeled receiver tracks, and delays UUID placeholders until a stable owner is
known. This keeps receiver FrameCryptors aligned with the participant ids used by
``RTCSession/setFrameEncryptionKey(_:index:for:)``.

After every Apple `setRemoteDescription`, PQSRTC reconciles both camera and audio receiver owners
from the remote SDP `msid` / `ssrc msid` lines. This is required because WebRTC can emit
`didAddReceiver` once with a UUID-like placeholder, then later advertise the stable publisher id
without emitting another receiver callback. Camera and audio must both be remapped before receiver
FrameCryptors are attached.

## Why Pairwise call_cipher Breaks Group Media

Pairwise `call_cipher` is correct for 1:1 media because there is exactly one sender and one
receiver for the media ratchet.

In a group call, one sender sends one encrypted RTP stream to the SFU and the SFU forwards that
same stream to multiple receivers. If the sender derives a different media key for each recipient,
there is no single key the sender FrameCryptor can use that all receivers can decrypt.

The failure mode is subtle: peers can agree on key index `0`, SDP/ICE can connect, and RTP can
flow, but each receiver has different key bytes. Audio and video then appear garbled, scrambled, or
fail with FrameCryptor `decryptionFailed` / `missingKey`.

## What Not To Do

Do not:

- derive group media frame keys from pairwise `call_cipher`
- install a group sender key under the room id
- mirror your local sender key into every remote participant slot
- bind receiver FrameCryptors to UUID placeholders when multiple remote senders exist
- bind only the video receiver to the stable publisher while leaving audio under the placeholder
- recreate PeerConnections or receivers to fix a key mismatch
- treat signaling-ratchet success as proof that media frame keys match

Do:

- keep group calls in per-participant key mode
- install the local sender key under the local participant id
- install each remote sender key under that remote sender id
- include `roomId`, `senderSecretName`, `keyIndex`, and key bytes in the host sender-key envelope
- fan out your local sender key immediately to known recipients and again when new participants or
  stable track owners appear
- keep roster updates flowing so clients can remove departed participants' receiver tracks and
  FrameCryptors
- preserve existing wire-field names during migrations unless both old and new clients are handled

## Relation To Signaling

Group SDP/ICE signaling still uses the SFU signaling ratchet and ``RTCTransportEvents/sendSfuMessage(_:call:)``.
That is separate from frame media keys.

The host app may choose to carry sender-key envelopes over the same message flag/channel it uses
for other call-control messages, but those envelopes must not be delivered into
``RTCSession/finishCryptoSessionCreation(ciphertext:call:)`` as pairwise `call_cipher` media
ratchet payloads.

In the Nudge host app, the sender-key envelope currently uses the metadata key
`conferenceFrameKey` for compatibility. That wire name is used for both channel-backed groups and
`conf-` conference rooms; the payload is still the app-injected per-sender frame key described in
this article.

## Regression Symptoms

Likely group sender-key regression:

- SFU registration succeeds
- ICE is connected
- sender/receiver tracks exist
- media works with FrameCryptor disabled
- encrypted media is garbled, scrambled, silent, or black
- video decrypts but audio is garbled or scrambled
- logs show receiver FrameCryptors bound to room ids, UUID placeholders, or ids with no
  provisioned key index
- logs show `Created receiver FrameCryptor kind=video participantId=<sender>` without a matching
  `kind=audio participantId=<sender>` after that sender key is provisioned

Likely non-E2EE media regression:

- media fails even with FrameCryptor disabled
- outbound RTP is not produced
- SDP/codec negotiation fails independently of keying

## Tests To Keep Updated

When changing this area, update tests for:

- true 1:1 SFU rooms remain on pairwise `call_cipher`
- channel-backed group rooms use app-injected sender frame keys
- `conf-` rooms use app-injected sender frame keys
- group receiver cryptors delay UUID placeholders
- `secretName_` stream labels normalize to `secretName`
- sender keys are not installed under room ids
- audio receiver owner reconciliation after stable SDP `msid` changes
- roster/SDP cleanup removes stale receiver FrameCryptors when participants leave

## Related Code

- `RTCSession+RTCCipherTransport.swift`: room-shape detection and pairwise `call_cipher` opt-out
- `RTCSession+PeerNotificationsHandler.swift`: receiver participant id binding, SDP owner
  reconciliation, and stale receiver cleanup
- `RTCSession+GroupCall.swift`: SFU registration, offer/answer/candidate control flow and roster
  cleanup
- ``RTCSession/setFrameEncryptionKey(_:index:for:)``
- ``RTCGroupCall``
- <doc:OneToOneSfuFrameE2EE>
