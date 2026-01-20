# Connecting to Servers (Signaling, TURN/Coturn, SFU)

PQSRTC is the **client-side** WebRTC + call orchestration + (optional) frame-level E2EE engine.
To establish calls, your app must connect to three server-side components:

1) **Signaling / control plane** (your backend): authentication, roster, offer/answer exchange, ICE candidate relay, and (optionally) E2EE key distribution messages.
2) **TURN (Coturn)**: reliable media connectivity when direct routes fail (NATs, cellular, enterprise networks).
3) **SFU** (for group calls): a WebRTC endpoint that forwards media between participants.

This guide explains what each server does, what your client needs to know, and how they work together.

## High-level topology

### 1:1 call

- Two clients negotiate a WebRTC connection.
- Signaling is used to exchange SDP and ICE.
- TURN is used as a fallback (or forced) relay path.

### Group call (SFU)

- Each client connects **one** PeerConnection to the SFU.
- Signaling is used to exchange SDP and ICE between each client and the SFU.
- TURN is used as a fallback relay for client↔SFU connectivity.

## 1) Signaling / control plane

### What it must do

Your signaling service is responsible for:

- Authenticating the user/device and issuing a session token.
- Creating/joining/leaving calls.
- Exchanging **SDP offers/answers**.
- Relaying **ICE candidates**.
- Publishing roster updates (for group calls).
- (Optional E2EE) transporting encrypted control messages used for handshake and/or sender-key distribution.

PQSRTC stays transport-agnostic. You provide an implementation of ``RTCTransportEvents`` and decide how to send these messages (WebSocket, HTTP+polling, gRPC, etc.).

### Minimum message types

Even if your wire format differs, these are the *semantic* operations you must support.

#### Offer

- **Outbound**: client generates an SDP offer and sends it to the signaling service.
- **Inbound**: signaling forwards it to the other party (1:1) or to the SFU (group).

#### Answer

- **1:1**: the callee generates an SDP answer and sends it back.
- **Group**: the SFU generates the SDP answer and sends it back.

#### ICE candidate

Both sides (or client and SFU) emit candidates over time; the signaling service must relay them to the other side.

#### Call lifecycle

At minimum you typically need:

- `createCall` / `joinCall`
- `leaveCall` / `endCall`
- optional: `rejectCall`, timeouts, and reconnect semantics

### Suggested event flow (SFU group call)

1) Client requests to join a call (`callId`, auth token).
2) Backend returns:
   - SFU routing identity (a string your app uses as `sfuRecipientId`)
   - ICE server list (STUN/TURN URLs and optional TURN credentials)
   - current participant roster
3) Client creates ``RTCSession`` + ``RTCGroupCall``, calls `join()`.
4) `RTCSession.createSFUIdentity(...)` triggers ``RTCTransportEvents/sendSfuMessage(_:call:)`` (with `packet.flag == .offer`).
5) Backend forwards offer to SFU, receives SFU answer, forwards answer back to client.
6) Backend relays ICE candidates between client and SFU.
7) Backend publishes roster updates as participants join/leave.

### Authentication & security notes

- Use TLS for all signaling transports.
- Prefer short-lived auth tokens (and short-lived TURN credentials).
- If you run E2EE, treat roster + identity binding as security-critical.

## 2) TURN (Coturn)

### What it is

TURN is a relay service used when direct connectivity is not possible. In practice, you almost always want TURN available for real-world networks.

### What the client needs

``RTCSession`` takes:

- `iceServers: [String]` — typically includes both STUN and TURN URIs
- `username: String` / `password: String` — TURN credentials (if your TURN requires auth)

Example ICE server list:

- `stun:stun.example.com:3478`
- `turn:turn.example.com:3478?transport=udp`
- `turns:turn.example.com:5349?transport=tcp`

Notes:

- Prefer offering **both UDP and TCP/TLS** TURN endpoints.
- Consider using coturn’s REST API mechanism (time-limited credentials) instead of static long-lived passwords.

### Coturn deployment checklist (practical)

- Open ports:
  - 3478/UDP + 3478/TCP (TURN)
  - 5349/TCP (TURN over TLS), if used
  - UDP relay range (e.g. 49152–65535/UDP)
- Set `external-ip` correctly when behind NAT.
- Log and rate-limit to reduce abuse.

## 3) SFU (Selective Forwarding Unit)

### What it must do

For PQSRTC group calls, the SFU must:

- Terminate a WebRTC PeerConnection per client.
- Receive each client’s published tracks.
- Forward appropriate tracks to each subscribing client.
- Support Unified Plan semantics (multiple tracks, multiple transceivers).

### What the client needs

- A stable **SFU identity** (string) used by the SDK to treat the SFU as the remote endpoint for that call.
- The signaling service must deliver the SFU’s answer and ICE candidates back to the client.
- A roster (participant ids) and any demux mapping your SFU requires.

If your SFU uses a non-default participant mapping, configure ``RTCSession/setRemoteParticipantIdResolver(_:)``.

## Putting it together: recommended configuration payload

A common pattern is for your backend to provide a single “join response” that contains everything the client needs.

Example shape (illustrative):

```json
{
  "callId": "...",
  "sfuRecipientId": "sfu",
  "iceServers": [
    "stun:stun.example.com:3478",
    "turn:turn.example.com:3478?transport=udp",
    "turns:turn.example.com:5349?transport=tcp"
  ],
  "turnUsername": "<ephemeral-username>",
  "turnPassword": "<ephemeral-password>",
  "participants": [
    { "id": "alice-device-1" },
    { "id": "bob-device-3" }
  ]
}
```

Your app can then construct:

- ``RTCSession``
- ``RTCGroupCall``

## Where to go next

- SFU group call flow details: <doc:Group-Calls>