# ``PQSRTC``

Client-side WebRTC for 1:1 and SFU group/conference calls, with optional frame-level E2EE.

## Overview

`PQSRTC` is transport-agnostic. The SDK owns WebRTC state; the host owns how messages move.

- Provide signaling via ``RTCTransportEvents``.
- Own PeerConnections and call lifecycle in ``RTCSession`` (`async` init).
- Join SFU rooms with ``RTCSession/groupCallNegotiation(call:sfuRecipientId:)``.
- Apply inbound SFU packets with ``RTCSession/handleControlMessage(_:)``.

For **SwiftSFU** + NeedleTail IRC, also read CallKit ordering, signaling flags, and frame E2EE articles below. The SFU forwards RTP and does not select frame keys.

### What you build vs what the SDK builds

Your app (or backend) is responsible for:

- Routing SDP / ICE / encrypted packets to the peer or SFU
- Delivering opaque `call_cipher` blobs for 1:1 media-ratchet exchange
- Distributing SFU group sender frame keys over an encrypted application route
- Maintaining roster for group calls

The SDK is responsible for:

- Creating and managing PeerConnections
- FrameCryptor / key-provider application
- Pairwise Double Ratchet used for 1:1 setup and 1:1 SFU `call_cipher`

### Group-call keying model

Encrypted SFU group media uses **application-injected per-sender frame keys**. Call
``RTCSession/setFrameEncryptionKey(_:index:for:)`` with the **sender** participant id. Do not
derive group media keys from pairwise `call_cipher`.

## Topics

### Quickstarts

- <doc:Getting-Started>
- <doc:Architecture>
- <doc:Group-Calls>

### Guides

- <doc:Connecting-to-Servers>
- <doc:Transport>
- <doc:One-to-One-Calls>
- <doc:End-to-End-Encryption>
- <doc:ScreenShare>
- <doc:GroupConferenceRemoteVideo>

### Server SFU, CallKit, and frame E2EE

- <doc:HostAppCallKitAndSFU>
- <doc:SFUSignalingOverview>
- <doc:OneToOneSfuFrameE2EE>
- <doc:GroupSfuFrameE2EE>
- <doc:SfuRemoteVideoFrameE2EE>

### Core Types

- ``RTCSession``
- ``RTCSession/CryptorConfiguration``
- ``RTCGroupCall``
- ``RTCTransportEvents``
- ``RTCSessionMediaEvents``

### Models

- ``Call``
- ``SessionDescription``
- ``IceCandidate``
- ``ConnectionLocalIdentity``

### E2EE

- ``RTCFrameEncryptionKeyMode``
- ``RatchetMessagePacket``
- ``PacketFlag``

## Building this documentation

- In **Xcode**: open the `pqs-rtc` package, select **PQSRTC**, then **Product → Build Documentation**.
- Catalog: `Sources/PQSRTC/PQSRTC.docc/`.

@Metadata {
  @DisplayName("PQSRTC")
}
