# ``PQSRTC``

Client-side WebRTC calling with SFU group calls and frame-level end-to-end encryption (E2EE).

## Overview

`PQSRTC` is intentionally *transport-agnostic*: the SDK handles WebRTC state, but your app owns how messages move over the network.

At a high level:

- You provide a control plane/signaling layer via ``RTCTransportEvents``.
- The SDK owns WebRTC state, negotiation, and call lifecycle inside ``RTCSession``.
- SFU group calls are driven by ``RTCGroupCall``.

For **server-SFU (SwiftSFU)** with NeedleTail-style signaling, also read the articles on **iOS + CallKit** media ordering, **SFU signaling** flags, and **per-participant frame E2EE** (remote video)—see the topics under *Server SFU, CallKit, and frame E2EE* below.

### What you build vs what the SDK builds

Your app (or backend) is responsible for:

- Routing SDP offers/answers and ICE candidates to the correct peer/SFU.
- Delivering opaque ciphertext blobs for 1:1 Double Ratchet / `call_cipher`.
- Distributing SFU group sender frame keys over your encrypted application route.
- Maintaining call membership/roster for group calls.

The SDK is responsible for:

- Creating and managing PeerConnections.
- Managing the encryption key provider / FrameCryptors for audio+video frames.
- Running pairwise Double Ratchet sessions used for 1:1 call setup and 1:1 SFU media-ratchet exchange.

### Group-call keying model

Encrypted SFU group media uses **application-injected per-sender frame keys**. Your app distributes
each sender's frame key over an encrypted application route, then calls
``RTCSession/setFrameEncryptionKey(_:index:for:)`` for the sender participant id. PQSRTC does not
derive group media frame keys from pairwise `call_cipher`; that path is reserved for 1:1 media.

## Topics

### Quickstarts

- <doc:Getting-Started>
- <doc:Group-Calls>

### Guides

- <doc:Connecting-to-Servers>
- <doc:Transport>
- <doc:One-to-One-Calls>
- <doc:End-to-End-Encryption>

### Server SFU, CallKit, and frame E2EE (NeedleTails)

- <doc:HostAppCallKitAndSFU> — iOS **CallKit** + server SFU **media bootstrap** ordering (inbound 1:1)
- <doc:SFUSignalingOverview> — control plane, ``PacketFlag``, duplicate `handshakeComplete`
- <doc:OneToOneSfuFrameE2EE> — `call_cipher`, frame identity props, and 1:1 SFU FrameCryptor key agreement
- <doc:GroupSfuFrameE2EE> — group/conference sender keys and the app-injected FrameCryptor contract
- <doc:SfuRemoteVideoFrameE2EE> — **remote video** and per-participant **FrameCryptor** identity (`msid`, 1:1 vs `conf-`)

### Core Types

- ``RTCSession``
- ``RTCGroupCall``
- ``RTCTransportEvents``
- ``RTCSessionMediaEvents``

### Models

- ``Call``
- ``SessionDescription``
- ``IceCandidate``

### E2EE

- ``RTCFrameEncryptionKeyMode``
- ``RatchetMessagePacket``
- ``PacketFlag``

## Building this documentation

- In **Xcode**: open the `pqs-rtc` package, select the **PQSRTC** target, then **Product → Build Documentation** (⌃⌥⌘D).
- The DocC catalog is a single bundle at `Sources/PQSRTC/PQSRTC.docc/` (articles under `Articles/`).

@Metadata {
  @DisplayName("PQSRTC")
}
