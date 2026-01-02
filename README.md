# PQSRTC

PQSRTC is a cross-platform real-time communications (RTC) core designed for Apple platforms (Swift) and Android (Kotlin) via [Skip](https://skip.tools).

It provides WebRTC session orchestration, call state/state-machine helpers, and optional frame-level end-to-end encryption (E2EE) primitives.

## Platforms

- Apple: iOS 18+, macOS 15+ (via Swift Package Manager)
- Android: via Skip transpilation (Swift → Kotlin)

## Installation

Add this package to your app via Swift Package Manager (Xcode: **File → Add Packages…**) and import `PQSRTC`.

## Quick start (Swift)

At the core is `RTCSession`, which requires your app to provide a transport delegate for exchanging offers/answers/ICE with your signaling layer.

```swift
import PQSRTC

let transport: RTCTransportEvents = /* your transport implementation */

let session = RTCSession(
	iceServers: ["stun:stun.l.google.com:19302"],
	username: "",
	password: "",
	delegate: transport
)
```

For multiparty, use `RTCGroupCall` (SFU-style) instead of building N×(N-1) peer connections.

## Building

### Apple (SwiftPM)

```sh
swift build
swift test
```

### Android (Skip)

Install Skip with Homebrew:

```sh
brew install skiptools/skip/skip
```

Skip will install the required prerequisites (Kotlin/Gradle/Android tooling) and can run parity tests:

```sh
skip android test
```

## Testing

- `swift test` runs the compiled Swift test suite on macOS.
- `skip android test` can run cross-platform parity testing (Swift + transpiled Kotlin/JUnit).

## Documentation

- Group calls (SFU): [Sources/PQSRTC/PQSRTC.docc/Articles/Group-Calls.md](Sources/PQSRTC/PQSRTC.docc/Articles/Group-Calls.md)
- Connecting to servers: [Sources/PQSRTC/PQSRTC.docc/Articles/Connecting-to-Servers.md](Sources/PQSRTC/PQSRTC.docc/Articles/Connecting-to-Servers.md)
- DocC: see [Sources/PQSRTC/PQSRTC.docc](Sources/PQSRTC/PQSRTC.docc)

## License

MIT. See [LICENSE](LICENSE).

