# Screen share

SFU group/conference screen share uses a fixed three-mid BUNDLE. Do not add a fourth mid.

## Mids

| Mid | Kind |
| --- | --- |
| `0` | Microphone (and mixed system/app audio while sharing) |
| `1` | Camera |
| `2` | Screen video |

The client contract is ``ScreenShareGroupCallContract``. SwiftSFU mirrors it as `ScreenShareGroupCallSFUContract`.

## Who may offer

Only these origins may send group/conference SDP offers:

1. Client media bootstrap after SFU registration
2. The sharer toggling capture (`sendGroupCallOffer` after add/remove screen track)
3. SFU receiver refresh when a forwarded screen appears or disappears

Do not originate extra offers from WebRTC `negotiationNeeded`.

## Preempt

A new sharer sends ``PacketFlag/screenSharePreempt`` before local capture starts. The prior sharer must stop. The SFU forwards that flag to the named former sharer.

## System audio

Captured app/system PCM is mixed into the **existing mic track (mid 0)**. Remotes already subscribed to that track hear it. The local mic track must stay published for remotes to receive the mix. Android system-audio capture is a host follow-up; this package’s mixer path is Apple-first.

## Related

- <doc:Group-Calls>
- <doc:SFUSignalingOverview>
- <doc:GroupConferenceRemoteVideo>
