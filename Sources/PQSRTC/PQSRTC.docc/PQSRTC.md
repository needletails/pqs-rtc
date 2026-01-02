# ``PQSRTC``

Client-side WebRTC calling with SFU group calls and frame-level end-to-end encryption (E2EE).

## Overview

`PQSRTC` is intentionally *transport-agnostic*: the SDK handles WebRTC state, but your app owns how messages move over the network.

At a high level:

- You provide a control plane/signaling layer via ``RTCTransportEvents``.
- The SDK owns WebRTC state, negotiation, and call lifecycle inside ``RTCSession``.
- SFU group calls are driven by ``RTCGroupCall``.

### What you build vs what the SDK builds

Your app (or backend) is responsible for:

- Routing SDP offers/answers and ICE candidates to the correct peer/SFU.
- Delivering opaque ciphertext blobs (for 1:1 Double Ratchet and optional group sender-key distribution).
- Maintaining call membership/roster for group calls.

The SDK is responsible for:

- Creating and managing PeerConnections.
- Managing the encryption key provider / FrameCryptors for audio+video frames.
- (Optional) Running pairwise Double Ratchet sessions used for 1:1 calls and group sender-key distribution.

### Group-call keying models

The SDK supports two group-call keying models:

- **Control-plane injected keys**: your app/server distributes frame keys and calls ``RTCGroupCall/setFrameEncryptionKey(_:index:for:)``.
- **Sender-key distribution**: each sender encrypts media with a per-sender key and distributes that key to other members using pairwise Double Ratchet messages.

> Tip: Start with control-plane injected keys if you already have an SFU + membership service. Move to sender keys when you want the SDK to handle pairwise encryption for sender-key distribution.

## Topics

### Quickstarts

- <doc:Getting-Started>
- <doc:Group-Calls>

### Guides

- <doc:Connecting-to-Servers>
- <doc:Transport>
- <doc:One-to-One-Calls>
- <doc:End-to-End-Encryption>

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
- ``RTCGroupE2EE``

@Metadata {
  @DisplayName("PQSRTC")
}
