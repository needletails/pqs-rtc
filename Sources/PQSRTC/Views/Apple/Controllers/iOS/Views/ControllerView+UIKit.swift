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

/// Full-screen ambient chrome for voice calls: gradient field + monogram, aligned with premium VoIP apps.
@MainActor
private final class VoiceCallChromeView: UIView {
    private let gradientLayer = CAGradientLayer()
    private let pulseRing = UIView()
    private let avatarCircle = UIView()
    private let monogramLabel = UILabel()
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
        addSubview(avatarCircle)

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

    func configure(monogram: String) {
        let trimmed = monogram.trimmingCharacters(in: .whitespacesAndNewlines)
        monogramLabel.text = trimmed.isEmpty ? "?" : trimmed.uppercased()
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

@MainActor
/// UIKit view used by the iOS in-call UI.
///
/// This view hosts call UI overlays (e.g. local preview) and provides
/// sizing/constraint helpers used by ``VideoCallViewController``.
class ControllerView: UIView {

    private var voiceCallChrome: VoiceCallChromeView?
    
    // MARK: - Local preview layout constraints (rotation-safe)
    private weak var currentPreviewView: NTMTKView?
    private var previewOverlayConstraints: [NSLayoutConstraint] = []
    private var previewFullscreenConstraints: [NSLayoutConstraint] = []
    private var previewWidthConstraint: NSLayoutConstraint?
    private var previewHeightConstraint: NSLayoutConstraint?
        
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
    
    // MARK: - Size Management (used by the view controller for preview layout)
    /// Computes the local preview size for the current device/orientation.
    ///
    /// - Parameters:
    ///   - isLandscape: Whether the UI should treat the interface as landscape.
    ///   - minimize: Whether the preview is in its minimized state.
    /// - Returns: The target size for the local preview overlay.
    func setSize(isLandscape: Bool, minimize: Bool) -> CGSize {
        var width: CGFloat = 0
        var height: CGFloat = 0
        
        if isLandscape {
            switch UIDevice.current.userInterfaceIdiom {
            case .phone:
                width = minimize ? (UIScreen.main.bounds.width / 4) : (UIScreen.main.bounds.width / 3)
                height = minimize ? (UIScreen.main.bounds.width / 4) / getAspectRatio(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height) : (UIScreen.main.bounds.width / 3) / getAspectRatio(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height)
            case .pad:
                width = minimize ? UIScreen.main.bounds.width / 3 : UIScreen.main.bounds.width / 4
                height = minimize ? (UIScreen.main.bounds.width / 3) / getAspectRatio(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height) : (UIScreen.main.bounds.width / 4) / getAspectRatio(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height)
            default:
                break
            }
        } else {
            switch UIDevice.current.userInterfaceIdiom {
            case .phone:
                width = minimize ? (UIScreen.main.bounds.width / 6.5) : UIScreen.main.bounds.height / 4.5
                height = minimize ? (UIScreen.main.bounds.width / 6.5) * getAspectRatio(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height) : (UIScreen.main.bounds.height / 5.5) * getAspectRatio(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height)
            case .pad:
                width = minimize ? UIScreen.main.bounds.height / 3 : UIScreen.main.bounds.height / 4
                height = minimize ? (UIScreen.main.bounds.height / 3) * getAspectRatio(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height) : (UIScreen.main.bounds.height / 4) * getAspectRatio(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height)
            default:
                break
            }
        }
        return CGSize(width: width, height: height)
    }
    
    /// Updates the local preview's constraints based on orientation and state.
    ///
    /// This no-ops while the app is backgrounded.
    func updateLocalVideoSize(with orientation: UIDeviceOrientation, should minimize: Bool, isConnected: Bool, view: NTMTKView, animated: Bool = true) {
        if UIApplication.shared.applicationState != .background {
            var size: CGSize = .zero
            switch orientation {
            case .unknown, .faceUp, .faceDown:
                if UIScreen.main.bounds.width < UIScreen.main.bounds.height {
                    size = setSize(isLandscape: false, minimize: minimize)
                } else {
                    size = setSize(isLandscape: true, minimize: minimize)
                }
            case .portrait, .portraitUpsideDown:
                size = setSize(isLandscape: false, minimize: minimize)
            case .landscapeRight, .landscapeLeft:
                size = setSize(isLandscape: true, minimize: minimize)
            default:
                size = setSize(isLandscape: true, minimize: minimize)
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await updateVideoConstraints(size: size, isConnected: isConnected, view: view, animated: animated)
            }
        }
    }
    
    /// Applies constraints to the preview view for connected vs. not-yet-connected layouts.
    func updateVideoConstraints(size: CGSize, isConnected: Bool, view: NTMTKView, animated: Bool) async {
        // Ensure we're constraining the view in the right hierarchy.
        guard view.superview === self else { return }
        
        // If the preview view instance changes (new call), drop old constraint references.
        if currentPreviewView !== view {
            NSLayoutConstraint.deactivate(previewOverlayConstraints + previewFullscreenConstraints)
            previewOverlayConstraints = []
            previewFullscreenConstraints = []
            previewWidthConstraint = nil
            previewHeightConstraint = nil
            currentPreviewView = view
        }
        
        view.translatesAutoresizingMaskIntoConstraints = false
        
        if isConnected {
            // Overlay mode: bottom-right "PiP-style" local preview.
            NSLayoutConstraint.deactivate(previewFullscreenConstraints)
            
            if previewOverlayConstraints.isEmpty {
                // Use safe-area so the preview never sits under the home indicator / notch.
                let bottom = view.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -16)
                let trailing = view.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -16)
                let width = view.widthAnchor.constraint(equalToConstant: max(1, size.width - 5))
                let height = view.heightAnchor.constraint(equalToConstant: max(1, size.height - 5))
                
                previewWidthConstraint = width
                previewHeightConstraint = height
                previewOverlayConstraints = [bottom, trailing, width, height]
                NSLayoutConstraint.activate(previewOverlayConstraints)
            } else {
                previewWidthConstraint?.constant = max(1, size.width - 5)
                previewHeightConstraint?.constant = max(1, size.height - 5)
            }
            
            // Match macOS PiP (`ControllerView+AppKit.updateVideoConstraints`): continuous corners + clip
            // so the Metal preview doesn’t draw square through a rounded frame.
            view.layer.cornerRadius = 10
            if #available(iOS 13.0, *) {
                view.layer.cornerCurve = .continuous
            }
            view.layer.masksToBounds = true
            view.layer.shadowOpacity = 0
        } else {
            // Fullscreen mode (pre-connect / local-only).
            NSLayoutConstraint.deactivate(previewOverlayConstraints)
            
            if previewFullscreenConstraints.isEmpty {
                previewFullscreenConstraints = [
                    view.topAnchor.constraint(equalTo: topAnchor),
                    view.leadingAnchor.constraint(equalTo: leadingAnchor),
                    view.bottomAnchor.constraint(equalTo: bottomAnchor),
                    view.trailingAnchor.constraint(equalTo: trailingAnchor)
                ]
                NSLayoutConstraint.activate(previewFullscreenConstraints)
            }
            
            // Reset rounding when fullscreen.
            view.layer.cornerRadius = 0
            view.layer.masksToBounds = false
            view.layer.shadowOpacity = 0
        }
        
        // Smooth resizing feels much more “polished”, especially when minimizing and rotating.
        if animated, window != nil {
            UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
                self.layoutIfNeeded()
            }
        }
    }

    // MARK: - Voice call chrome (audio-only)
    /// Shows or hides the full-screen voice backdrop behind video layers and SwiftUI controls.
    func setVoiceCallChromeVisible(_ visible: Bool, monogram: String = "") {
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
            chrome.configure(monogram: monogram)
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
    
    // MARK: - Aspect Ratio Calculation
    /// Returns $\frac{\max(width, height)}{\min(width, height)}$.
    private func getAspectRatio(width: CGFloat, height: CGFloat) -> CGFloat {
        max(width, height) / min(width, height)
    }
}
#endif

