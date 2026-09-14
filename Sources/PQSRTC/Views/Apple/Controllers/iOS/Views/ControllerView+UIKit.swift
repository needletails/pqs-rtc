//
//  ControllerView+UIKit.swift
//  pqs-rtc
//
//  Created by Cole M on 1/11/25.
//
//  Copyright (c) 2025 NeedleTails Organization.
//
//  This project is licensed under the MIT License.
//
//  See the LICENSE file for more information.
//
//
//  This file is part of the PQSRTC SDK, which provides
//  Frame Encrypted VoIP Capabilities
//

#if os(iOS)
import UIKit

// MARK: - Voice call backdrop (audio-only)

/// Full-screen ambient chrome for voice calls: gradient field + avatar/monogram, aligned with premium VoIP apps.
@MainActor
private final class VoiceCallChromeView: UIView {
    private let gradientLayer = CAGradientLayer()
    private let pulseRing = UIView()
    private let avatarCircle = UIView()
    private let monogramLabel = UILabel()
    private let avatarImageView = UIImageView()
    private let iconView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.insertSublayer(gradientLayer, at: 0)

        gradientLayer.startPoint = CGPoint(x: 0.1, y: 0)
        gradientLayer.endPoint = CGPoint(x: 0.9, y: 1)
        gradientLayer.colors = [
            UIColor(red: 0.04, green: 0.09, blue: 0.18, alpha: 1).cgColor,
            UIColor(red: 0.07, green: 0.16, blue: 0.28, alpha: 1).cgColor,
            UIColor(red: 0.03, green: 0.12, blue: 0.22, alpha: 1).cgColor
        ]
        gradientLayer.locations = [0, 0.45, 1]

        pulseRing.translatesAutoresizingMaskIntoConstraints = false
        pulseRing.backgroundColor = .clear
        pulseRing.layer.borderWidth = 2
        pulseRing.layer.borderColor = UIColor.white.withAlphaComponent(0.22).cgColor
        pulseRing.layer.cornerCurve = .continuous
        pulseRing.layer.cornerRadius = 72
        addSubview(pulseRing)

        avatarCircle.translatesAutoresizingMaskIntoConstraints = false
        avatarCircle.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        avatarCircle.layer.cornerCurve = .continuous
        avatarCircle.layer.cornerRadius = 64
        avatarCircle.layer.borderWidth = 1.5
        avatarCircle.layer.borderColor = UIColor.white.withAlphaComponent(0.28).cgColor
        avatarCircle.clipsToBounds = true
        addSubview(avatarCircle)

        avatarImageView.translatesAutoresizingMaskIntoConstraints = false
        avatarImageView.contentMode = .scaleAspectFill
        avatarImageView.clipsToBounds = true
        avatarImageView.isHidden = true
        avatarCircle.addSubview(avatarImageView)

        monogramLabel.translatesAutoresizingMaskIntoConstraints = false
        monogramLabel.font = .systemFont(ofSize: 40, weight: .semibold)
        monogramLabel.textColor = .white
        monogramLabel.textAlignment = .center
        monogramLabel.adjustsFontSizeToFitWidth = true
        monogramLabel.minimumScaleFactor = 0.5
        avatarCircle.addSubview(monogramLabel)

        let symbol = UIImage(systemName: "phone.fill")?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 22, weight: .medium))
        iconView.image = symbol
        iconView.tintColor = UIColor.white.withAlphaComponent(0.55)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentMode = .scaleAspectFit
        addSubview(iconView)

        NSLayoutConstraint.activate([
            pulseRing.centerXAnchor.constraint(equalTo: centerXAnchor),
            pulseRing.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -28),
            pulseRing.widthAnchor.constraint(equalToConstant: 144),
            pulseRing.heightAnchor.constraint(equalToConstant: 144),

            avatarCircle.centerXAnchor.constraint(equalTo: pulseRing.centerXAnchor),
            avatarCircle.centerYAnchor.constraint(equalTo: pulseRing.centerYAnchor),
            avatarCircle.widthAnchor.constraint(equalToConstant: 128),
            avatarCircle.heightAnchor.constraint(equalToConstant: 128),

            avatarImageView.topAnchor.constraint(equalTo: avatarCircle.topAnchor),
            avatarImageView.leadingAnchor.constraint(equalTo: avatarCircle.leadingAnchor),
            avatarImageView.bottomAnchor.constraint(equalTo: avatarCircle.bottomAnchor),
            avatarImageView.trailingAnchor.constraint(equalTo: avatarCircle.trailingAnchor),

            monogramLabel.centerXAnchor.constraint(equalTo: avatarCircle.centerXAnchor),
            monogramLabel.centerYAnchor.constraint(equalTo: avatarCircle.centerYAnchor),
            monogramLabel.leadingAnchor.constraint(greaterThanOrEqualTo: avatarCircle.leadingAnchor, constant: 8),
            monogramLabel.trailingAnchor.constraint(lessThanOrEqualTo: avatarCircle.trailingAnchor, constant: -8),

            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.topAnchor.constraint(equalTo: pulseRing.bottomAnchor, constant: 28),
            iconView.widthAnchor.constraint(equalToConstant: 32),
            iconView.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer.frame = bounds
    }

    func configure(monogram: String, avatarImage: UIImage? = nil) {
        if let avatarImage {
            avatarImageView.image = avatarImage
            avatarImageView.isHidden = false
            monogramLabel.isHidden = true
        } else {
            avatarImageView.image = nil
            avatarImageView.isHidden = true
            monogramLabel.isHidden = false
            let trimmed = monogram.trimmingCharacters(in: .whitespacesAndNewlines)
            monogramLabel.text = trimmed.isEmpty ? "?" : trimmed.uppercased()
        }
    }

    func startAmbientMotion() {
        pulseRing.layer.removeAnimation(forKey: "voicePulse")
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = 1.06
        scale.duration = 2.4
        scale.autoreverses = true
        scale.repeatCount = .infinity
        scale.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulseRing.layer.add(scale, forKey: "voicePulse")

        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0.55
        opacity.toValue = 1.0
        opacity.duration = 2.4
        opacity.autoreverses = true
        opacity.repeatCount = .infinity
        opacity.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulseRing.layer.add(opacity, forKey: "voicePulseOpacity")
    }

    func stopAmbientMotion() {
        pulseRing.layer.removeAllAnimations()
    }
}

/// Clips the local preview at the UIKit compositor. `CAMetalLayer` / `AVCaptureVideoPreviewLayer`
/// ignore `cornerRadius` until a later composition (a drag); a parent `UIView` clips immediately
/// once Auto Layout assigns the PiP frame.
@MainActor
private final class LocalPreviewClipHostView: UIView {
    var cornerRadiusValue: CGFloat = 0 {
        didSet { applyClipIfNeeded() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear
        isOpaque = false
        clipsToBounds = true
        layer.needsDisplayOnBoundsChange = true
        if #available(iOS 13.0, *) {
            layer.cornerCurve = .continuous
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyClipIfNeeded()
    }

    private func applyClipIfNeeded() {
        let hasSize = bounds.width > 1 && bounds.height > 1
        let radius = hasSize ? cornerRadiusValue : 0
        clipsToBounds = radius > 0
        layer.cornerRadius = radius
        layer.masksToBounds = radius > 0
        if #available(iOS 13.0, *) {
            layer.cornerCurve = .continuous
        }
        revealIfClipReady(hasSize: hasSize, appliedRadius: radius)
    }

    /// Stay hidden until this layout pass has a real frame and, for overlay, the rounded clip.
    /// The first visible frame is then already clipped — not square, then rounded.
    fileprivate func revealIfClipReady(hasSize: Bool? = nil, appliedRadius: CGFloat? = nil) {
        guard isHidden else { return }
        let sized = hasSize ?? (bounds.width > 1 && bounds.height > 1)
        guard sized else { return }
        if cornerRadiusValue > 0 {
            let radius = appliedRadius ?? layer.cornerRadius
            guard radius > 0 else { return }
        }
        isHidden = false
        for subview in subviews {
            subview.isHidden = false
        }
    }
}

@MainActor
/// UIKit view used by the iOS in-call UI.
///
/// This view hosts call UI overlays (e.g. local preview) and provides
/// sizing/constraint helpers used by ``VideoCallViewController``.
class ControllerView: UIView {

    private var voiceCallChrome: VoiceCallChromeView?
    
    // MARK: - Local preview layout constraints (rotation-safe)
    private weak var currentPreviewView: NTMTKView?
    private let localPreviewClipHost = LocalPreviewClipHostView()
    private var previewFillHostConstraints: [NSLayoutConstraint] = []
    private var previewOverlayConstraints: [NSLayoutConstraint] = []
    private var previewFullscreenConstraints: [NSLayoutConstraint] = []
    private var previewWidthConstraint: NSLayoutConstraint?
    private var previewHeightConstraint: NSLayoutConstraint?
    private let connectedPreviewCornerRadius: CGFloat = 16
        
    // MARK: - Blur support (used by the view controller)
    /// Blur effect used when obscuring video (e.g. during local mute).
    let blurEffect = UIBlurEffect(style: .dark)
    /// Active blur effect view, if currently installed.
    var blurEffectView: UIVisualEffectView?
    
    // MARK: - Initializers
    override init(frame: CGRect) {
        super.init(frame: frame)
    }
    
    required init?(coder aDecoder: NSCoder) {
        assertionFailure("ControllerView is intended to be initialized programmatically")
        return nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        guard let currentPreviewView else { return }
        let isConnectedPreviewLayout = currentPreviewView.superview === localPreviewClipHost
            && previewOverlayConstraints.contains(where: \.isActive)
        applyLocalPreviewCornerStyle(isConnected: isConnectedPreviewLayout, to: currentPreviewView)
    }
    
    // MARK: - Size Management (used by the view controller for preview layout)
    /// Computes the local preview size for the current device/orientation.
    ///
    /// - Parameters:
    ///   - isLandscape: Whether the UI should treat the interface as landscape.
    ///   - minimize: Whether the preview is in its minimized state.
    /// - Returns: The target size for the local preview overlay.
    func setSize(isLandscape: Bool, minimize: Bool, containerSize: CGSize? = nil) -> CGSize {
        let fallback: CGSize
        if bounds.width > 1, bounds.height > 1 {
            fallback = bounds.size
        } else {
            fallback = UIScreen.main.bounds.size
        }
        let explicit = containerSize.flatMap { size -> GroupCallLayoutSize? in
            guard size.width > 1, size.height > 1 else { return nil }
            return GroupCallLayoutSize(width: Double(size.width), height: Double(size.height))
        }
        let container = GroupCallVideoLayoutPolicy.resolvedLocalPreviewHostSize(
            explicitContainer: explicit,
            fallbackContainer: GroupCallLayoutSize(
                width: Double(fallback.width),
                height: Double(fallback.height)
            ),
            requestedIsLandscape: isLandscape
        )
        let policy = GroupCallVideoLayoutPolicy.localPreviewOverlaySize(
            platform: .iOS,
            containerSize: container,
            isTablet: UIDevice.current.userInterfaceIdiom == .pad,
            isMinimized: minimize
        )
        return CGSize(width: policy.width, height: policy.height)
    }
    
    /// Updates the local preview's constraints based on orientation and state.
    ///
    /// This no-ops while the app is backgrounded.
    func updateLocalVideoSize(
        with orientation: UIDeviceOrientation,
        should minimize: Bool,
        isConnected: Bool,
        view: NTMTKView,
        animated: Bool = true,
        containerSize: CGSize? = nil
    ) {
        if UIApplication.shared.applicationState != .background {
            let fallbackBox = bounds.width > 1 && bounds.height > 1
                ? bounds.size
                : UIScreen.main.bounds.size
            let isLandscape: Bool
            if let containerSize, containerSize.width > 1, containerSize.height > 1 {
                isLandscape = containerSize.width > containerSize.height
            } else {
                switch orientation {
                case .portrait, .portraitUpsideDown:
                    isLandscape = false
                case .landscapeLeft, .landscapeRight:
                    isLandscape = true
                default:
                    isLandscape = fallbackBox.width > fallbackBox.height
                }
            }
            let size = setSize(
                isLandscape: isLandscape,
                minimize: minimize,
                containerSize: containerSize
            )
            updateVideoConstraints(size: size, isConnected: isConnected, view: view, animated: animated)
        }
    }

    /// Hide the overlay until the host has a PiP frame and rounded clip, so the first
    /// visible frame is already clipped. No-op when a clipped overlay is already on screen.
    func hideLocalPreviewUntilOverlayClipIsReady(_ view: NTMTKView) {
        let alreadyClipped = localPreviewClipHost.superview === self
            && !localPreviewClipHost.isHidden
            && localPreviewClipHost.bounds.width > 1
            && localPreviewClipHost.bounds.height > 1
            && localPreviewClipHost.cornerRadiusValue > 0
            && localPreviewClipHost.layer.cornerRadius > 0
        if alreadyClipped {
            view.isHidden = false
            return
        }
        view.isHidden = true
        localPreviewClipHost.isHidden = true
    }

    /// Embeds the local preview in the clipping host and brings the host to the front.
    func attachConnectedLocalPreview(_ view: NTMTKView) {
        hideLocalPreviewUntilOverlayClipIsReady(view)
        if localPreviewClipHost.superview !== self {
            addSubview(localPreviewClipHost)
        }
        if view.superview !== localPreviewClipHost {
            NSLayoutConstraint.deactivate(previewFillHostConstraints)
            previewFillHostConstraints = []
            view.removeFromSuperview()
            view.translatesAutoresizingMaskIntoConstraints = false
            localPreviewClipHost.addSubview(view)
            let fill = [
                view.topAnchor.constraint(equalTo: localPreviewClipHost.topAnchor),
                view.leadingAnchor.constraint(equalTo: localPreviewClipHost.leadingAnchor),
                view.bottomAnchor.constraint(equalTo: localPreviewClipHost.bottomAnchor),
                view.trailingAnchor.constraint(equalTo: localPreviewClipHost.trailingAnchor)
            ]
            previewFillHostConstraints = fill
            NSLayoutConstraint.activate(fill)
        }
        currentPreviewView = view
        bringSubviewToFront(localPreviewClipHost)
    }

    func bringConnectedLocalPreviewToFront() {
        guard localPreviewClipHost.superview === self else { return }
        bringSubviewToFront(localPreviewClipHost)
    }

    /// The view that owns overlay position (drag / snap). Metal content is a child of this host.
    var connectedLocalPreviewDragView: UIView? {
        guard localPreviewClipHost.superview === self else { return currentPreviewView }
        return localPreviewClipHost
    }

    func detachLocalPreviewFromOverlay() {
        currentPreviewView?.removeFromSuperview()
        localPreviewClipHost.removeFromSuperview()
        NSLayoutConstraint.deactivate(
            previewOverlayConstraints + previewFullscreenConstraints + previewFillHostConstraints
        )
        previewOverlayConstraints = []
        previewFullscreenConstraints = []
        previewFillHostConstraints = []
        previewWidthConstraint = nil
        previewHeightConstraint = nil
        currentPreviewView = nil
        localPreviewClipHost.cornerRadiusValue = 0
        localPreviewClipHost.isHidden = true
    }
    
    /// Applies constraints to the preview view for connected vs. not-yet-connected layouts.
    func updateVideoConstraints(size: CGSize, isConnected: Bool, view: NTMTKView, animated: Bool) {
        let isInHost = view.superview === localPreviewClipHost
        guard isInHost || view.superview === self else { return }

        if isConnected {
            attachConnectedLocalPreview(view)
        }

        if currentPreviewView !== view {
            NSLayoutConstraint.deactivate(previewOverlayConstraints + previewFullscreenConstraints)
            previewOverlayConstraints = []
            previewFullscreenConstraints = []
            previewWidthConstraint = nil
            previewHeightConstraint = nil
            currentPreviewView = view
        }

        let pinned = localPreviewClipHost.superview === self ? localPreviewClipHost : view
        pinned.translatesAutoresizingMaskIntoConstraints = false
        let isFirstConnectedOverlay = isConnected && previewOverlayConstraints.isEmpty

        if isConnected {
            NSLayoutConstraint.deactivate(previewFullscreenConstraints)
            if previewOverlayConstraints.isEmpty {
                let bottom = pinned.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -16)
                let trailing = pinned.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -16)
                let width = pinned.widthAnchor.constraint(equalToConstant: max(1, size.width - 5))
                let height = pinned.heightAnchor.constraint(equalToConstant: max(1, size.height - 5))
                previewWidthConstraint = width
                previewHeightConstraint = height
                previewOverlayConstraints = [bottom, trailing, width, height]
                NSLayoutConstraint.activate(previewOverlayConstraints)
            } else {
                previewWidthConstraint?.constant = max(1, size.width - 5)
                previewHeightConstraint?.constant = max(1, size.height - 5)
            }
        } else {
            NSLayoutConstraint.deactivate(previewOverlayConstraints)
            if previewFullscreenConstraints.isEmpty {
                previewFullscreenConstraints = [
                    pinned.topAnchor.constraint(equalTo: topAnchor),
                    pinned.leadingAnchor.constraint(equalTo: leadingAnchor),
                    pinned.bottomAnchor.constraint(equalTo: bottomAnchor),
                    pinned.trailingAnchor.constraint(equalTo: trailingAnchor)
                ]
                NSLayoutConstraint.activate(previewFullscreenConstraints)
            }
        }

        // Set the host radius before layout so the first PiP frame is already clipped.
        localPreviewClipHost.cornerRadiusValue = isConnected ? connectedPreviewCornerRadius : 0

        // First overlay pin must not animate from fullscreen: a 16pt radius on a phone-sized
        // presentation layer looks square until the animation finishes.
        let shouldAnimate = animated && window != nil && !isFirstConnectedOverlay
        if shouldAnimate {
            UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
                self.layoutIfNeeded()
                self.applyLocalPreviewCornerStyle(isConnected: isConnected, to: view)
            } completion: { [weak self, weak view] _ in
                guard let self, let view else { return }
                self.applyLocalPreviewCornerStyle(isConnected: isConnected, to: view)
            }
        } else {
            setNeedsLayout()
            layoutIfNeeded()
            applyLocalPreviewCornerStyle(isConnected: isConnected, to: view)
        }
    }

    func applyConnectedLocalPreviewCornerStyle(to view: NTMTKView) {
        applyLocalPreviewCornerStyle(isConnected: true, to: view)
    }

    private func applyLocalPreviewCornerStyle(isConnected: Bool, to view: NTMTKView) {
        let radius = isConnected ? connectedPreviewCornerRadius : 0
        localPreviewClipHost.cornerRadiusValue = radius
        localPreviewClipHost.setNeedsLayout()
        localPreviewClipHost.layoutIfNeeded()
        view.setNeedsLayout()
        view.layoutIfNeeded()
        syncLocalPreviewMediaFrames(on: view)
        localPreviewClipHost.revealIfClipReady()
    }

    private func syncLocalPreviewMediaFrames(on view: NTMTKView) {
        guard let captureView = view.captureView, captureView.superview === view else { return }
        if captureView.frame != view.bounds {
            captureView.frame = view.bounds
        }
        captureView.layer.frame = captureView.bounds
        if let previewCaptureView = captureView as? PreviewCaptureView,
           previewCaptureView.previewLayer.frame != previewCaptureView.bounds {
            previewCaptureView.previewLayer.frame = previewCaptureView.bounds
        }
    }

    // MARK: - Voice call chrome (audio-only)
    /// Shows or hides the full-screen voice backdrop behind video layers and SwiftUI controls.
    func setVoiceCallChromeVisible(_ visible: Bool, monogram: String = "", avatarImage: UIImage? = nil) {
        if visible {
            let chrome = voiceCallChrome ?? VoiceCallChromeView()
            if voiceCallChrome == nil {
                voiceCallChrome = chrome
                chrome.translatesAutoresizingMaskIntoConstraints = false
                insertSubview(chrome, at: 0)
                NSLayoutConstraint.activate([
                    chrome.topAnchor.constraint(equalTo: topAnchor),
                    chrome.leadingAnchor.constraint(equalTo: leadingAnchor),
                    chrome.bottomAnchor.constraint(equalTo: bottomAnchor),
                    chrome.trailingAnchor.constraint(equalTo: trailingAnchor)
                ])
            }
            chrome.configure(monogram: monogram, avatarImage: avatarImage)
            chrome.isHidden = false
            chrome.startAmbientMotion()
        } else {
            voiceCallChrome?.stopAmbientMotion()
            voiceCallChrome?.isHidden = true
        }
    }

    func removeVoiceCallChrome() {
        voiceCallChrome?.stopAmbientMotion()
        voiceCallChrome?.removeFromSuperview()
        voiceCallChrome = nil
    }
}
#endif
