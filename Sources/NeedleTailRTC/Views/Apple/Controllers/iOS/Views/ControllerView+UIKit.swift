//
//  ControllerView+UIKit.swift
//  needle-tail-rtc
//
//  Created by Cole M on 1/11/25.
//
//  Copyright (c) 2025 NeedleTails Organization.
//
//  This project is proprietary and confidential.
//
//  All rights reserved. Unauthorized copying, distribution, or use
//  of this software is strictly prohibited.
//
//  This file is part of the NeedleTailRTC SDK, which provides
//  VoIP Capabilities
//
#if os(iOS)
import UIKit

@MainActor
class ControllerView: UIView {
    
    // MARK: - UI Elements
    let calleeLabel: UILabel = {
        let lbl = UILabel()
        lbl.textAlignment = .center
        lbl.textColor = .gray
        lbl.font = .systemFont(ofSize: 16, weight: .light)
        return lbl
    }()
    
    let statusLabel: UILabel = {
        let lbl = UILabel()
        lbl.textAlignment = .center
        lbl.textColor = .gray
        lbl.font = .systemFont(ofSize: 16, weight: .light)
        return lbl
    }()

    private let controlsStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.distribution = .equalSpacing
        stack.spacing = 8
        return stack
    }()
    
    private let verticalPhoneStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.distribution = .equalSpacing
        stack.spacing = 8
        return stack
    }()
    
    let blurEffect = UIBlurEffect(style: .dark)
    var blurEffectView: UIVisualEffectView?
    var canUpgradeDowngrade = true {
        didSet {
            if canUpgradeDowngrade {
                verticalPhoneStack.addArrangedSubview(upgradeDowngradeMedia)
            }
        }
    }
    
    lazy var endButton: UIImageView = ControllerView.createButton(
        imageName: "phone.down.circle.fill",
        color: .red,
        buttonSize: .init(width: 35, height: 35))

    lazy var muteAudioButton: UIImageView = ControllerView.createButton(
        imageName: "speaker.circle.fill",
        color: .blue,
        buttonSize: .init(width: 35, height: 35))
    lazy var muteVideoButton: UIImageView = ControllerView.createButton(
        imageName: "video.circle.fill",
        color: .blue,
        buttonSize: .init(width: 35, height: 35))
    lazy var speakerPhoneButton: UIImageView = ControllerView.createButton(
        imageName: "speaker.wave.3",
        color: .blue,
        buttonSize: .init(width: 35, height: 35))
    lazy var upgradeDowngradeMedia: UIImageView = ControllerView.createButton(
        imageName: "arrow.up.right.video.fill",
        color: .blue,
        buttonSize: .init(width: 30, height: 30))
    
    // MARK: - Properties
    var voiceImageData: Data?
    var calleeProfileImageView: UIImageView?
    
    // MARK: - Initializers
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Setup
    private func setupView() {
        addSubviews()
        setupConstraints()
    }
    
    func addVerticalControls() {
        addSubview(verticalPhoneStack)
        verticalPhoneStack.addArrangedSubview(speakerPhoneButton)
        verticalPhoneStack.anchors(
            top: topAnchor,
            trailing: trailingAnchor,
            paddingTop: 100,
            paddingRight: 20,
            width: 48,
            height: 96)
        bringSubviewToFront(verticalPhoneStack)
        
        speakerPhoneButton.anchors(width: 30, height: 30)
        upgradeDowngradeMedia.anchors(width: 30, height: 30)
    }
    
    private func addSubviews() {
        
        addSubview(statusLabel)
        addSubview(controlsStack)
       
        
        // Add buttons to stacks
        controlsStack.addArrangedSubview(muteVideoButton)
        controlsStack.addArrangedSubview(muteAudioButton)
        controlsStack.addArrangedSubview(endButton)
        
        muteVideoButton.anchors(width: 35, height: 35)
        muteAudioButton.anchors(width: 35, height: 35)
        endButton.anchors(width: 35, height: 35)
     
    }
    
    private func setupConstraints() {
        // Use your custom anchors method for layout
        let statusLabelSize = statusLabel.sizeThatFits(.init(width: .greatestFiniteMagnitude, height: statusLabel.frame.size.height))
        statusLabel.anchors(
            top: topAnchor,
            centerX: centerXAnchor,
            paddingTop: 60,
            width: statusLabelSize.width,
            height: statusLabelSize.height)
        
        controlsStack.anchors(
            bottom: bottomAnchor,
            trailing: trailingAnchor,
            paddingBottom: 20,
            paddingRight: 40,
            width: 180,
            height: 40)
    }
    
    // MARK: - Button Creation
    private static func createButton(imageName: String, color: UIColor, buttonSize: CGSize) -> UIImageView {
        // Load the image for the normal state
        let normalImage = UIImage(systemName: imageName)
        
        // Create the UIImageView
        let imageView = UIImageView(image: normalImage)
        imageView.frame = CGRect(origin: .zero, size: buttonSize)
        imageView.tintColor = color // Set the tint color for the image
        imageView.contentMode = .scaleAspectFit // Adjust content mode as needed
        imageView.isUserInteractionEnabled = true // Enable user interaction

        return imageView
    }
    
    // MARK: - Constraints Management
    private func deactivateConstraints(for view: UIView) {
        for constraint in view.constraints {
            if constraint.isActive {
                constraint.isActive = false
            }
        }
    }

    
    // MARK: - View Management
    func addConnectedVoiceViews() async {
        if let voiceImageData = voiceImageData {
            let voiceImage = UIImage(data: voiceImageData)?
                .circularImage(size: CGSize(width: UIScreen.main.bounds.width / 2, height: UIScreen.main.bounds.width / 2), borderWidth: 5, borderColor: .blue)
            calleeProfileImageView = UIImageView(image: voiceImage)
        } else {
            let voiceImage = UIImage(named: "Nudge")?
                .circularImage(size: CGSize(width: UIScreen.main.bounds.width / 2, height: UIScreen.main.bounds.width / 2), borderWidth: 5, borderColor: .blue)
            calleeProfileImageView = UIImageView(image: voiceImage)
        }
        
        if let calleeImageView = calleeProfileImageView {
            addSubview(calleeImageView)
            calleeImageView.anchors(
                centerY: centerYAnchor,
                centerX: centerXAnchor,
                width: UIScreen.main.bounds.width / 2,
                height: UIScreen.main.bounds.width / 2
            )
        }
        
        addSubview(calleeLabel)
        
        let calleeLabelSize = calleeLabel.sizeThatFits(.init(width: .greatestFiniteMagnitude, height: calleeLabel.frame.size.height))
        calleeLabel.anchors(
            leading: leadingAnchor,
            bottom: bottomAnchor,
            paddingLeft: 40,
            paddingBottom: 30,
            width: calleeLabelSize.width,
            height: calleeLabelSize.height
        )
    }
    
    func removeConnectedVoiceViews() {
        calleeProfileImageView?.removeFromSuperview()
        calleeLabel.removeFromSuperview()
    }
    
    func removeLocalVideoView() {
        for view in subviews where view is NTMTKView {
            view.removeFromSuperview()
        }
    }
    
    func addConnectedLocalVideoView(view: NTMTKView) async {
        addSubview(view)
        updateLocalVideoSize(
            with: UIDevice.current.orientation,
            should: false,
            isConnected: true,
            view: view)
        bringSubviewToFront(view)
        self.bringControlsToFront()
    }
    
    func bringControlsToFront() {
        bringSubviewToFront(statusLabel)
        bringSubviewToFront(controlsStack)
        bringSubviewToFront(statusLabel)
    }
    
    // MARK: - Size Management
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
    
    func updateVideoConstraints(size: CGSize, isConnected: Bool, view: NTMTKView) async {
        if isConnected {
            view.anchors(
                bottom: bottomAnchor,
                trailing: trailingAnchor,
                paddingBottom: 80,
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
    private func getAspectRatio(width: CGFloat, height: CGFloat) -> CGFloat {
        return max(width, height) / min(width, height)
    }
    
    // MARK: - Call Type State
    enum CallTypeState {
        case base, video, voice
    }
}
#endif

