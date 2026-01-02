//
//  UIView+Extension.swift
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

extension UIView {
    /// Returns `true` if the fade-in/out looping animation is currently active.
    var isFadingLooping: Bool {
        get {
            return layer.animationKeys()?.contains("fadeInOutLoop") ?? false
        }
    }
    
    /// Starts an infinite fade in/out loop by recursively chaining `UIView.animate` calls.
    ///
    /// - Parameter duration: Duration for each fade phase.
    func fadeInOutLoop(duration: TimeInterval) {
        guard !isFadingLooping else {
            return
        }
        
        UIView.animate(withDuration: duration, animations: {
            self.alpha = 1.0
        }) { _ in
            UIView.animate(withDuration: duration, animations: {
                self.alpha = 0.0
            }) { _ in
                self.fadeInOutLoop(duration: duration)
            }
        }
    }
    
    /// Stops the fade loop by removing view layer animations.
    func stopFadeInOutLoop() {
        layer.removeAllAnimations()
    }
    
    /// Convenience helper for setting up Auto Layout constraints.
    ///
    /// This pins edges/centers and optionally sets fixed width/height constraints.
    public func anchors(
        top: NSLayoutYAxisAnchor? = nil,
        leading: NSLayoutXAxisAnchor? = nil,
        bottom: NSLayoutYAxisAnchor? = nil,
        trailing: NSLayoutXAxisAnchor? = nil,
        centerY: NSLayoutYAxisAnchor? = nil,
        centerX: NSLayoutXAxisAnchor? = nil,
        paddingTop: CGFloat = 0,
        paddingLeft: CGFloat = 0,
        paddingBottom: CGFloat = 0,
        paddingRight: CGFloat = 0,
        width: CGFloat = 0,
        height: CGFloat = 0,
        lessThanEqualToWidth: CGFloat = 0) {
            translatesAutoresizingMaskIntoConstraints = false
            if let top = top {
                self.topAnchor.constraint(equalTo: top, constant: paddingTop).isActive = true
            }
            if let leading = leading {
                self.leadingAnchor.constraint(equalTo: leading, constant: paddingLeft).isActive = true
            }
            if let bottom = bottom {
                self.bottomAnchor.constraint(equalTo: bottom, constant: -paddingBottom).isActive = true
            }
            if let trailing = trailing {
                self.trailingAnchor.constraint(equalTo: trailing, constant: -paddingRight).isActive = true
            }
            if let centerX = centerX {
                self.centerXAnchor.constraint(equalTo: centerX).isActive = true
            }
            if let centerY = centerY {
                self.centerYAnchor.constraint(equalTo: centerY).isActive = true
            }
            if width != 0 {
                widthAnchor.constraint(equalToConstant: width).isActive = true
            }
            if height != 0 {
                heightAnchor.constraint(equalToConstant: height).isActive = true
            }
            if lessThanEqualToWidth != 0 {
                widthAnchor.constraint(lessThanOrEqualToConstant: width).isActive = true
            }
        }
}
#endif
