//
//  VideoCallWithNetworkQualityBanner.swift
//  pqs-rtc
//
//  SwiftUI convenience wrapper that overlays a simple quality banner.
//

#if !os(Android)
import Foundation
import SwiftUI

/// SwiftUI wrapper around `VideoCallViewControllerRepresentable` that shows a small banner
/// when network quality changes (poor ↔ recovered).
@MainActor
public struct VideoCallWithNetworkQualityBanner: View {
    private let session: RTCSession
    @Binding private var delegate: CallActionDelegate?
    @Binding private var errorMessage: String
    @Binding private var endedCall: Bool
    @Binding private var width: CGFloat
    @Binding private var height: CGFloat
    @Binding private var callState: CallStateMachine.State
    private let controlsView: AnyView?

    @State private var qualityObserver = RTCNetworkQualityEventObserver()
    @State private var banner: BannerState?

    private struct BannerState: Equatable, Sendable {
        let title: String
        let subtitle: String?
        let style: Style

        enum Style: Sendable {
            case ok
            case warn
            case bad
        }
    }

    public init(
        session: RTCSession,
        delegate: Binding<CallActionDelegate?>,
        errorMessage: Binding<String>,
        endedCall: Binding<Bool>,
        width: Binding<CGFloat>,
        height: Binding<CGFloat>,
        callState: Binding<CallStateMachine.State>,
        controlsView: AnyView? = nil
    ) {
        self.session = session
        self._delegate = delegate
        self._errorMessage = errorMessage
        self._endedCall = endedCall
        self._width = width
        self._height = height
        self._callState = callState
        self.controlsView = controlsView
    }

    public init<Controls: View>(
        session: RTCSession,
        delegate: Binding<CallActionDelegate?>,
        errorMessage: Binding<String>,
        endedCall: Binding<Bool>,
        width: Binding<CGFloat>,
        height: Binding<CGFloat>,
        callState: Binding<CallStateMachine.State>,
        @ViewBuilder controlsView: () -> Controls
    ) {
        self.init(
            session: session,
            delegate: delegate,
            errorMessage: errorMessage,
            endedCall: endedCall,
            width: width,
            height: height,
            callState: callState,
            controlsView: AnyView(controlsView())
        )
    }

    public var body: some View {
        ZStack(alignment: .top) {
            VideoCallViewControllerRepresentable(
                session: session,
                delegate: $delegate,
                errorMessage: $errorMessage,
                endedCall: $endedCall,
                width: $width,
                height: $height,
                callState: $callState,
                controlsView: controlsView
            )

            if let banner {
                NetworkQualityBanner(title: banner.title, subtitle: banner.subtitle, style: banner.style)
                    .padding(.top, 12)
                    .padding(.horizontal, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(10)
            }
        }
        .task {
            qualityObserver.start(session: session)
            // Consume the observer’s stream so we can animate and auto-hide.
            for await update in qualityObserver.createLatestStream() {
                await handleQualityUpdate(update)
            }
        }
        .onDisappear {
            qualityObserver.stop()
        }
    }

    private func handleQualityUpdate(_ update: RTCNetworkQualityUpdate) async {
        let q = update.quality
        let bitrate = update.availableOutgoingBitrateBps.map { "\($0 / 1000) kbps" }
        let rtt = update.rttMs.map { "\($0) ms" }

        func subtitleLine() -> String? {
            switch (bitrate, rtt) {
            case (nil, nil): return nil
            case (let b?, nil): return "Uplink \(b)"
            case (nil, let r?): return "RTT \(r)"
            case (let b?, let r?): return "Uplink \(b) • RTT \(r)"
            }
        }

        let newBanner: BannerState?
        switch q {
        case .veryPoor:
            newBanner = .init(title: "Very poor connection", subtitle: subtitleLine(), style: .bad)
        case .poor:
            newBanner = .init(title: "Poor connection", subtitle: subtitleLine(), style: .bad)
        case .fair:
            newBanner = .init(title: "Unstable network", subtitle: subtitleLine(), style: .warn)
        case .good, .excellent:
            // If we were showing a warning banner, briefly show recovered then hide.
            if banner != nil {
                newBanner = .init(title: "Connection recovered", subtitle: subtitleLine(), style: .ok)
            } else {
                newBanner = nil
            }
        }

        if let newBanner {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
                banner = newBanner
            }
            // Auto-hide recovery banners quickly; keep poor banners visible until improvement.
            if newBanner.style == .ok {
                Task.detached { [weak session] in
                    _ = session // keep signature stable; no-op
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    await MainActor.run {
                        withAnimation(.easeOut(duration: 0.2)) {
                            banner = nil
                        }
                    }
                }
            }
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                banner = nil
            }
        }
    }
}

private struct NetworkQualityBanner: View {
    let title: String
    let subtitle: String?
    let style: VideoCallWithNetworkQualityBanner.BannerState.Style

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(iconColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 6)
    }

    private var iconName: String {
        switch style {
        case .ok: return "wifi"
        case .warn: return "wifi.exclamationmark"
        case .bad: return "wifi.exclamationmark"
        }
    }

    private var iconColor: Color {
        switch style {
        case .ok: return .green
        case .warn: return .yellow
        case .bad: return .red
        }
    }

    private var borderColor: Color {
        switch style {
        case .ok: return .green.opacity(0.35)
        case .warn: return .yellow.opacity(0.35)
        case .bad: return .red.opacity(0.35)
        }
    }
}

#endif

