# PQSRTC

[![Swift](https://img.shields.io/badge/Swift-6.3+-orange.svg)](https://swift.org)
[![Platform](https://img.shields.io/badge/Platform-iOS%2018%2B%20%7C%20macOS%2015%2B-blue.svg)](https://developer.apple.com)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

Client-side WebRTC for Nudge: 1:1 calls, SFU group/conference calls, and optional frame-level E2EE. The SDK is transport-agnostic. Your app implements ``RTCTransportEvents`` and owns signaling. For NeedleTails production, that control plane is Nudge Server + [SwiftSFU](https://github.com/needletails/swift-sfu).

Android uses the same Swift sources via [Skip](https://skip.tools). Package.swift platforms are iOS 18+ and macOS 15+. The host app sets the Android min SDK.

## What this SDK is (and is not)

- **Is:** PeerConnection lifecycle, SDP/ICE, SFU group-call state, FrameCryptor key application, 1:1 media-ratchet (`call_cipher`), screen-share contract (audio mid `0`, camera `1`, screen `2`).
- **Is not:** A signaling server, an SFU, or a TURN service. SwiftSFU forwards RTP and does **not** pick frame keys.
- **Is not:** A reason to rotate Nudge account keys. Session/media keys here are call-scoped.

## Installation

Add the package with Swift Package Manager and `import PQSRTC`.

## Quick start

`RTCSession` is an actor. Construction is `async`. Frame-encryption mode lives on `CryptorConfiguration` (default `.perParticipant`).

```swift
import PQSRTC

let session = await RTCSession(
    iceServers: ["stun:stun.l.google.com:19302"],
    username: "",
    password: "",
    cryptorConfig: .init(mode: .perParticipant),
    delegate: transport
)
```

- **1:1:** identity exchange + `finishCryptoSessionCreation` / `handleOffer` / `handleAnswer` / `handleCandidate`. If the call is relayed through an SFU room, also read **OneToOneSfuFrameE2EE**.
- **Group / conference:** `groupCallNegotiation(call:sfuRecipientId:)` is the production join path. It creates the ``RTCGroupCall``, registers with the SFU, and later bootstraps media. Feed inbound packets with ``RTCSession/handleControlMessage(_:)``. Inject per-sender frame keys with ``RTCSession/setFrameEncryptionKey(_:index:for:)``.

Do not construct N×(N−1) mesh PeerConnections for multiparty.

## Documentation (DocC)

Single catalog: [`Sources/PQSRTC/PQSRTC.docc/`](Sources/PQSRTC/PQSRTC.docc/). In Xcode: **Product → Build Documentation**.

| Article | Use when |
| --- | --- |
| [Getting Started](Sources/PQSRTC/PQSRTC.docc/Articles/Getting-Started.md) | First integration |
| [Architecture](Sources/PQSRTC/PQSRTC.docc/Articles/Architecture.md) | 1:1 vs group vs conference planes |
| [Transport](Sources/PQSRTC/PQSRTC.docc/Articles/Transport.md) | `RTCTransportEvents` routing |
| [Connecting to Servers](Sources/PQSRTC/PQSRTC.docc/Articles/Connecting-to-Servers.md) | Signaling, TURN, SwiftSFU |
| [One-to-One Calls](Sources/PQSRTC/PQSRTC.docc/Articles/One-to-One-Calls.md) | Direct or SFU-relayed 1:1 |
| [Group Calls](Sources/PQSRTC/PQSRTC.docc/Articles/Group-Calls.md) | SFU join, roster, control messages |
| [End-to-End Encryption](Sources/PQSRTC/PQSRTC.docc/Articles/End-to-End-Encryption.md) | FrameCryptor model |
| [Host app + CallKit + SFU](Sources/PQSRTC/PQSRTC.docc/Articles/HostAppCallKitAndSFU.md) | iOS inbound audio ordering |
| [SFU signaling overview](Sources/PQSRTC/PQSRTC.docc/Articles/SFUSignalingOverview.md) | Flags, `handshakeComplete`, no extra offers |
| [1:1 SFU frame E2EE](Sources/PQSRTC/PQSRTC.docc/Articles/OneToOneSfuFrameE2EE.md) | `call_cipher` |
| [Group SFU frame E2EE](Sources/PQSRTC/PQSRTC.docc/Articles/GroupSfuFrameE2EE.md) | App-injected sender keys |
| [Remote video / FrameCryptor ids](Sources/PQSRTC/PQSRTC.docc/Articles/SfuRemoteVideoFrameE2EE.md) | Black tiles with E2EE on |
| [Group conference remote video](Sources/PQSRTC/PQSRTC.docc/Articles/GroupConferenceRemoteVideo.md) | Multiparty camera tiles |
| [Screen share](Sources/PQSRTC/PQSRTC.docc/Articles/ScreenShare.md) | Mids, preempt, system audio |

## Building and testing

```sh
swift build
swift test
```

Android parity (Skip):

```sh
brew install skiptools/skip/skip
skip android test
```

## Production notes

- **ICE:** default policy is `allThenRelay` (4s), then relay. TURN credentials go in `username` / `password`. Prefer time-limited TURN REST credentials from your backend.
- **H264:** `RTCSession.modifySDP` caps Constrained Baseline `42e034` → `42e028` (level 4.0). Do not force `42e01f` for 1080p; that can stall the sender after a few hundred frames.
- **iOS inbound SFU:** do not create SFU media before CallKit activates audio. Use `setRequiresExternalAudioActivation(true)` and `markExternalAudioActivationComplete()` plus the host contract in **HostAppCallKitAndSFU**.
- **Group E2EE:** never derive group media keys from pairwise `call_cipher`. Install sender keys under participant ids, not room ids.
- **Renegotiation:** only the documented offer origins (media bootstrap, sharer screen toggle, SFU receiver refresh). Do not fire extra offers from `negotiationNeeded`.

## License

MIT. See [LICENSE](LICENSE).
