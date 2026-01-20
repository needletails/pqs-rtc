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

@MainActor
/// UIKit view used by the iOS in-call UI.
///
/// This view hosts call UI overlays (e.g. local preview) and provides
/// sizing/constraint helpers used by ``VideoCallViewController``.
class ControllerView: UIView {
    
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
            
            view.layer.cornerRadius = 10
            if #available(iOS 13.0, *) {
                view.layer.cornerCurve = .continuous
            }
            view.layer.masksToBounds = true
            // Subtle shadow reads as “premium” and improves depth separation from remote video.
            view.layer.shadowColor = UIColor.black.cgColor
            view.layer.shadowOpacity = 0.18
            view.layer.shadowRadius = 12
            view.layer.shadowOffset = CGSize(width: 0, height: 6)
            view.layer.masksToBounds = false
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
    
    // MARK: - Aspect Ratio Calculation
    /// Returns $\frac{\max(width, height)}{\min(width, height)}$.
    private func getAspectRatio(width: CGFloat, height: CGFloat) -> CGFloat {
        max(width, height) / min(width, height)
    }
}
#endif

