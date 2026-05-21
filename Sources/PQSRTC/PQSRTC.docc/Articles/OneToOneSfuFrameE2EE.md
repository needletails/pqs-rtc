# 1:1 SFU frame E2EE and call_cipher

This article documents the production contract between PQSRTC, the host transport, and WebRTC
FrameCryptors for encrypted 1:1 calls relayed through an SFU room.

Read this before changing:

- ``RTCTransportEvents/sendCiphertext(recipient:connectionId:ciphertext:call:)``
- `RTCSession+RTCCipherTransport.swift`
- `RTCSession+PeerNotificationsHandler.swift`
- ``Call/frameIdentityProps`` or ``Call/signalingIdentityProps`` transport behavior

The short version: **`call_cipher` is the media-ratchet identity exchange.** It is not SDP, not
ICE, and not an SFU instruction. It carries opaque PQXDH bootstrap bytes plus a ``Call`` whose
identity props must describe the sender of that `call_cipher` payload.

## Why this exists

In a direct 1:1 call, the remote participant id and the WebRTC connection id usually point at the
same peer. In a 1:1-over-SFU call, the WebRTC PeerConnection is routed through an ephemeral room
such as `#<uuid>`. That room id is useful for signaling and SFU media routing, but it is not the
owner of encrypted media frames.

FrameCryptor keys are looked up by participant id:

- outbound media uses the local sender participant id
- inbound media uses the remote track owner's participant id

For a 1:1 SFU relay, those are the two users in the call, not the SFU room id.

## The three planes

Keep these planes separate:

| Plane | Purpose | Identity material |
| --- | --- | --- |
| Transport routing | Gets a message to a peer or room | `recipient`, `connectionId`, SFU room ids |
| Signaling ratchet | Protects SDP, ICE, and control payloads | ``Call/signalingIdentityProps`` |
| Frame media ratchet | Derives FrameCryptor keys | ``Call/frameIdentityProps`` |

Signaling keys and frame keys are different. A signaling-ratchet success proves that SDP/control
messages can decrypt; it does not prove media frames can decrypt.

## Host transport contract

When PQSRTC calls ``RTCTransportEvents/sendCiphertext(recipient:connectionId:ciphertext:call:)``,
the host app must deliver exactly these fields to the remote `receiveCiphertext` path:

- `recipient`: app-level peer routing id, normally the peer `secretName`
- `connectionId`: stable call/connection id, normally ``Call/sharedCommunicationId``
- `ciphertext`: opaque PQXDH bootstrap bytes; do not parse or transform
- `call`: the ``Call`` payload with current identity props

The concrete wire format is host-defined. For example, a host can serialize:

```swift
metadata: [
  "ciphertext": ciphertext,
  "call": BinaryEncoder().encode(call)
]
```

That shape is intentionally enough. Do not add an extra `callCipherTarget`, `call_cipher_target`,
or other target side channel to fix key mismatches. If routing is wrong, fix routing. If identity
props are wrong, fix the ``Call`` payload. Extra target fields create a second source of truth and
make it easy for the two peers to derive different frame keys.

## Outbound call_cipher

`setMessageKey(connection:call:force:)` is the sender-side entry point.

Before PQSRTC sends a `call_cipher`, it refreshes the outgoing ``Call``:

- ``Call/frameIdentityProps`` becomes this device's current local frame identity
- ``Call/signalingIdentityProps`` becomes this device's current local signaling identity

This is required because the `Call` object may have been merged from an inbound payload and may
still contain the remote peer's props. Sending stale remote props makes the receiver initialize its
media ratchet against the wrong identity.

In per-participant mode, the derived sender frame key is installed only under:

```swift
connection.localParticipantId
```

That is the slot used by sender FrameCryptors. The sender key must not be mirrored into:

- the SFU room id
- the remote peer id
- every known participant

Mirroring hides bugs in 1:1 and breaks multi-party calls because those slots represent different
senders or different ratchet directions.

## Inbound call_cipher

`receiveCiphertext(recipient:ciphertext:call:)` is the receive-side entry point.

The inbound ``Call`` must carry the sender's authoritative identity props:

- ``Call/frameIdentityProps``: remote peer frame/media identity
- ``Call/signalingIdentityProps``: remote peer signaling identity

PQSRTC replaces any stored provisional recipient identity with `call.frameIdentityProps` before
deriving the receive frame key. This is important because early SFU media bootstrap can create a
temporary room/SFU identity before the real peer identity arrives.

The receive key is installed under the remote track owner participant id, not necessarily
`connection.remoteParticipantId`. In true 1:1 SFU rooms, `connection.remoteParticipantId` can be
the room id; the remote track owner is the peer `secretName`.

## Fresh ciphertext means fresh receive chain

Every distinct `call_cipher` ciphertext is a fresh media-ratchet bootstrap.

Duplicate detection keys on:

- normalized connection id
- exact ciphertext bytes

That means an exact duplicate is ignored, but a refreshed `call_cipher` with different bytes is
processed. The receive-side media ratchet session id includes the inbound ciphertext fingerprint so
the refreshed receive key starts at frame key index `0`.

Do not "simplify" this into a receive session keyed only by connection id and peer id. That advances
the old receive chain to index `1` while the sender restarted at index `0`, and FrameCryptors will
report missing keys even though both sides exchanged ciphers.

## Sender refresh after peer identity update

If this client already derived a sender key using a provisional remote frame identity, and a later
inbound `call_cipher` provides the peer's concrete frame identity, PQSRTC forces one sender refresh.

That refresh:

- clears the sender-key provisioned marker for the connection
- derives the sender media ratchet against the new remote identity
- sends a fresh `call_cipher` containing this device's local identity props

The goal is symmetry: the receiver derives its receive key from the same remote frame identity and
the same fresh ciphertext the sender used.

## Receiver FrameCryptor binding

The receive key and the receiver FrameCryptor must agree on the same participant id.

For true 1:1 SFU:

- UUID-like stream ids can be temporary SFU placeholders
- stream ids such as `alice_` can be WebRTC `msid` labels, not key ids
- self-labeled receiver tracks must not get receiver FrameCryptors

`RTCSession+PeerNotificationsHandler.swift` normalizes these cases so receiver FrameCryptors bind
to the same remote track owner used by `setReceivingMessageKey`.

For multi-party or `conf-` rooms, do not apply 1:1 remaps broadly. Multi-party rooms need per-sender
keys, and guessing from a UUID placeholder can attach the wrong key to the wrong sender.

## Media readiness ordering

For encrypted 1:1 SFU calls, post-cipher `.handshakeComplete` is sent after the receive key is
installed. Sending it earlier can let SFU media start while receiver FrameCryptors have no key.

When frame encryption is disabled, PQSRTC can send the readiness signal without waiting for a
receive frame key.

This distinction is why disabling FrameCryptor can make media render while encrypted media does
not: SDP/ICE and SFU routing can be correct while the frame-key contract is still broken.

## What not to do

Do not:

- derive frame keys from signaling identity props
- use the SFU room id as the per-participant frame-key owner
- mirror sender keys into the peer/room slots in per-participant mode
- drop or replace ``Call/frameIdentityProps`` on `call_cipher`
- add a second target field for `call_cipher` routing
- recreate receivers or PeerConnections to fix a frame-key mismatch
- call `createOffer` again after post-cipher setup for an already-offered SFU PeerConnection
- treat every inbound `call_cipher` on a connection as the next index of one receive chain

Do:

- preserve `ciphertext`, `connectionId`, and the encoded ``Call`` payload
- refresh outbound `call_cipher` calls with local frame and signaling props
- replace provisional recipient frame identity when inbound `call_cipher` arrives
- install sender keys under the local participant id
- install receive keys under the remote track owner
- include the inbound ciphertext fingerprint in receive media-ratchet session identity
- wait for receive-key readiness before binding encrypted 1:1 SFU receiver FrameCryptors

## Regression symptoms

Likely `call_cipher` / FrameCryptor identity regression:

- ICE is connected
- sender/receiver tracks exist
- SFU is forwarding RTP
- media renders when FrameCryptor is disabled
- encrypted remote media does not render
- logs show FrameCryptor `missingKey`, `decryptionFailed`, or empty/room/UUID participant ids

Likely non-E2EE media regression:

- media fails even with FrameCryptor disabled
- sender is not producing frames
- SDP codec/profile negotiation differs between peers and SFU

See <doc:SfuRemoteVideoFrameE2EE> for the receiver-id rules and SDP note.

## Tests to keep updated

When changing this area, update or add tests for:

- true 1:1 SFU room detection vs `conf-` rooms
- sender key participant id is local
- receive key participant id is remote track owner
- UUID/underscore receiver id normalization
- exact duplicate `call_cipher` is ignored
- refreshed `call_cipher` derives receive key index `0`
- post-cipher `.handshakeComplete` waits for receive key when FrameCryptor is enabled

## Related code

- `RTCSession+RTCCipherTransport.swift`: sender/receive media-ratchet setup and `call_cipher`
- `RTCSession+PeerNotificationsHandler.swift`: receiver FrameCryptor participant id binding
- `RTCSession+Exchange.swift`: post-cipher signaling payloads without duplicate offers
- `KeyManager.swift`: recipient identity replacement while preserving ciphertext
- ``RTCTransportEvents/sendCiphertext(recipient:connectionId:ciphertext:call:)``
- ``Call/frameIdentityProps``
- ``Call/signalingIdentityProps``
