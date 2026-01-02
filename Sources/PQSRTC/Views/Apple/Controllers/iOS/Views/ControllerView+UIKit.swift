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
    func updateLocalVideoSize(with orientation: UIDeviceOrientation, should minimize: Bool, isConnected: Bool, view: NTMTKView) {
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
                guard let self = self else { return }
                await updateVideoConstraints(size: size, isConnected: isConnected, view: view)
            }
        }
    }
    
    /// Applies constraints to the preview view for connected vs. not-yet-connected layouts.
    func updateVideoConstraints(size: CGSize, isConnected: Bool, view: NTMTKView) async {
        if isConnected {
            view.anchors(
                bottom: bottomAnchor,
                trailing: trailingAnchor,
                paddingBottom: 100,
                paddingRight: 20,
                width: size.width - 5,
                height: size.height - 5
            )
            
            view.layer.cornerRadius = 10
            view.layer.masksToBounds = true
        } else {
            view.anchors(
                top: topAnchor,
                leading: leadingAnchor,
                bottom: bottomAnchor,
                trailing: trailingAnchor
            )
        }
    }
    
    // MARK: - Aspect Ratio Calculation
    /// Returns $\frac{\max(width, height)}{\min(width, height)}$.
    private func getAspectRatio(width: CGFloat, height: CGFloat) -> CGFloat {
        max(width, height) / min(width, height)
    }
}
#endif

