# Architecture

How PQSRTC splits transport, signaling, and media.

## Planes

Keep these separate. Mixing them is the usual cause of silent or garbled SFU media.

| Plane | Owned by | Identity |
| --- | --- | --- |
| Transport routing | Host app / Nudge Server / SwiftSFU | `recipient`, `connectionId`, IRC channel / room id |
| Signaling ratchet | PQSRTC `TaskProcessor` | ``Call/signalingIdentityProps`` |
| Frame media | FrameCryptor + KeyProvider | Participant id (`secretName`), not the room id |
| RTP forward | SwiftSFU | Room membership; no frame keys |

PQSRTC never opens sockets. ``RTCTransportEvents`` is the only outbound path.

## Call shapes

### Direct 1:1

Two clients, one PeerConnection (or P2P ICE). SDP/ICE on ``RTCSession``. Optional shared or per-participant frame keys. `call_cipher` is the 1:1 media-ratchet identity exchange.

### 1:1 over SFU

Still two users. The PeerConnection terminates on SwiftSFU in an ephemeral `#<uuid>` room. `channelWireId` marks the SFU route; ``Call/resolvedChannelWireId`` stays `nil` so frame keys stay peer-oriented. Read <doc:OneToOneSfuFrameE2EE> and <doc:HostAppCallKitAndSFU>.

### Channel group or `conf-` conference

One PeerConnection to the SFU, many inbound tracks (Unified Plan). Media keys are **per-sender**, injected by the host with ``RTCSession/setFrameEncryptionKey(_:index:for:)``. Pairwise `call_cipher` cannot represent one outbound RTP stream to many receivers. Read <doc:Group-Calls> and <doc:GroupSfuFrameE2EE>.

Personal conference rooms (`#conf-<stem>-u<owner-tag>`) keep host rights on the owning account. That rule is enforced by SwiftSFU, not by this SDK.

## Session objects

- **``RTCSession``** — one per app runtime. Owns PeerConnections, CallKit audio gate, conference permission state, and control-message ingress.
- **``RTCGroupCall``** — per-room facade (roster, events). Created by ``RTCSession/groupCallNegotiation(call:sfuRecipientId:)``. Do not treat `join()` as “media is up”; media starts after SFU registration + ``beginGroupCallMediaAfterSfuRegistrationIfNeeded(sfuRecipientId:)``.
- **``RTCTransportEvents``** — host signaling.

## ICE and media

Default ICE strategy is ``RTCIceTransportPolicyStrategy/allThenRelay(timeoutMilliseconds:)`` (4 seconds). TURN username/password are session constructor arguments.

Screen share uses fixed BUNDLE mids: audio `0`, camera `1`, screen `2`. See <doc:ScreenShare>.

## Related

- <doc:Getting-Started>
- <doc:Connecting-to-Servers>
- SwiftSFU DocC: Architecture, Security Model, Client Integration
