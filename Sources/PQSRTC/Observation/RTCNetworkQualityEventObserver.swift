//
//  RTCNetworkQualityEventObserver.swift
//  pqs-rtc
//
//  SwiftUI-friendly observer (Observation.framework) over `RTCSession` network quality events.
//

import Foundation

#if canImport(Observation)
import Observation
#endif

/// SwiftUI-friendly wrapper for observing coarse network quality changes.
///
/// This uses the "NeedleTailKit EventObserver" pattern:
/// - **one observable property** (`latest`)
/// - **one setter** (`setLatest`) that installs `withObservationTracking` and yields to a lazily-created stream
@MainActor
#if canImport(Observation)
@Observable
#endif
public final class RTCNetworkQualityEventObserver {
    /// Latest network-quality update, if any.
    public var latest: RTCNetworkQualityUpdate?

    /// Convenience: latest quality bucket.
    public var quality: RTCNetworkQuality? { latest?.quality }

    /// Whether the SDK currently believes conditions are materially poor.
    public var isPoor: Bool {
        switch latest?.quality {
        case .poor, .veryPoor:
            return true
        default:
            return false
        }
    }

    // `deinit` is nonisolated; cancellation is thread-safe.
    nonisolated(unsafe) private var task: Task<Void, Never>?

    // MARK: - Observation-backed stream (NeedleTailKit-style)
    public private(set) var latestStream: AsyncStream<RTCNetworkQualityUpdate>?
    private var latestContinuation: AsyncStream<RTCNetworkQualityUpdate>.Continuation?

    public init() {}

    deinit {
        task?.cancel()
    }

    /// Starts (or restarts) observing `session` network quality events.
    public func start(session: RTCSession) {
        stop()
        task = Task { [weak self] in
            guard let self else { return }
            let stream = await session.createNetworkQualityStream()
            for await update in stream {
                if Task.isCancelled { return }
                self.setLatest(update)
            }
        }
    }

    /// Stops observing and leaves `latest` as-is.
    public func stop() {
        task?.cancel()
        task = nil
    }

    /// Sets the latest update and yields it over `latestStream`.
    ///
    /// This matches the NeedleTailKit pattern:
    /// - lazily create stream
    /// - install `withObservationTracking { self.latest } onChange { yield(latest) }`
    /// - then update `latest`
    /// Returns (and lazily creates) the stream that emits whenever `latest` changes.
    public func createLatestStream() -> AsyncStream<RTCNetworkQualityUpdate> {
        if latestStream == nil {
            makeLatestStream()
        }
        // Safe: we just created it if it was nil.
        return latestStream!
    }

    public func setLatest(_ update: RTCNetworkQualityUpdate) {
        if latestStream == nil {
            makeLatestStream()
        }

#if canImport(Observation)
        _ = withObservationTracking {
            self.latest
        } onChange: { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard let latest = self.latest else { return }
                self.latestContinuation?.yield(latest)
            }
        }
#endif

        latest = update

#if !canImport(Observation)
        latestContinuation?.yield(update)
#endif
    }

    private func makeLatestStream() {
        latestStream = AsyncStream<RTCNetworkQualityUpdate> { [weak self] (continuation: AsyncStream<RTCNetworkQualityUpdate>.Continuation) in
            guard let self else { return }
            self.latestContinuation = continuation
        }
    }
}

