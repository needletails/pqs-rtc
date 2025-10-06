//
//  ControllerView+AppKit.swift
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
#if os(macOS)
import AppKit
import NeedleTailLogger

@MainActor
class ControllerView: NSView {
    
    let scrollView = VideoCallScrollView()
    var voiceImageData: Data?
    var calleeProfileImageView: NSImageView?
    
    let calleeLabel: NSTextField = {
        let txt = NSTextField.newLabel()
        txt.textColor = Constants.OFF_WHITE_COLOR
        txt.backgroundColor = NSColor(red: 30/255, green: 30/255, blue: 30/255, alpha: 1)
        txt.font = .systemFont(ofSize: 12, weight: .light)
        return txt
    }()
    
    let statusLabel: NSTextField = {
        let txt = NSTextField.newLabel()
        txt.textColor = Constants.OFF_WHITE_COLOR
        txt.backgroundColor = NSColor(red: 30/255, green: 30/255, blue: 30/255, alpha: 1)
        txt.font = .systemFont(ofSize: 12, weight: .light)
        txt.sizeToFit()
        return txt
    }()
    
    var labelMessage: String {
        get {
            statusLabel.stringValue
        }
    }
    
    private let controlsStack: NSStackView = {
        var stackView = NSStackView()
        stackView.orientation = .horizontal
        stackView.alignment = .centerX
        stackView.distribution = .equalCentering
        stackView.spacing = 10
        stackView.alignment = .bottom
        return stackView
    }()
    
    private static func createButton(imageName: String, color: NSColor, buttonSize: CGSize) -> NSImageView {
        // Load the images for normal and selected states
        let normalImage = NSImage(systemSymbolName: imageName, accessibilityDescription: nil)
        
        // Create the NSImageView
        let view = NSImageView(image: normalImage!)
        view.frame = NSRect(origin: .zero, size: buttonSize)
        view.contentTintColor = color
        view.image?.size = buttonSize
        view.imageScaling = .scaleProportionallyUpOrDown
        view.layer?.masksToBounds = true
        view.wantsLayer = true
        
        view.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        view.setContentHuggingPriority(.defaultHigh, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
        
        let hoverEffect = NSTrackingArea(
            rect: view.bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited],
            owner: view,
            userInfo: nil
        )
        view.addTrackingArea(hoverEffect)
        
        view.target = view
        return view
    }
    
    override func mouseEntered(with event: NSEvent) {
        if let view = event.trackingArea?.owner as? NSImageView {
            view.layer?.opacity = 0.6 // Reduce opacity to 60% on hover
        }
    }
    
    override func mouseExited(with event: NSEvent) {
        if let view = event.trackingArea?.owner as? NSImageView {
            view.layer?.opacity = 1.0 // Full opacity when mouse is not hovering
        }
    }
    
    var canUpgradeDowngrade = true {
        didSet {
            if canUpgradeDowngrade {
                addSubview(upgradeDowngradeMedia)
                upgradeDowngradeMedia.anchors(
                    top: topAnchor,
                    trailing: trailingAnchor,
                    paddingBottom: 10,
                    paddingTrailing: 10,
                    width: 30,
                    height: 30)
                self.layoutSubtreeIfNeeded()
            }
        }
    }
    
    lazy var endButton: NSImageView = ControllerView.createButton(
        imageName: "phone.down.circle.fill",
        color: .red,
        buttonSize: .init(width: 35, height: 35))
    lazy var muteAudioButton: NSImageView = ControllerView.createButton(
        imageName: "speaker.circle.fill",
        color: .blue,
        buttonSize: .init(width: 35, height: 35))
    lazy var muteVideoButton: NSImageView = ControllerView.createButton(
        imageName: "video.circle.fill",
        color: .blue,
        buttonSize: .init(width: 35, height: 35))
    lazy var upgradeDowngradeMedia: NSImageView = ControllerView.createButton(
        imageName: "arrow.up.right.video.fill",
        color: .blue,
        buttonSize: .init(width: 30, height: 30))
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        
    }
    
    func tearDownView() {
        scrollView.removeFromSuperview()
        calleeProfileImageView?.removeFromSuperview()
        controlsStack.removeFromSuperview()
        statusLabel.removeFromSuperview()
        calleeLabel.removeFromSuperview()
        upgradeDowngradeMedia.removeFromSuperview()
        voiceImageData = nil
        calleeProfileImageView = nil
        deactivateConstraints(for: statusLabel)
        deactivateConstraints(for: controlsStack)
        deactivateConstraints(for: calleeLabel)
        if let calleeProfileImageView {
            deactivateConstraints(for: calleeProfileImageView)
        }
        deactivateConstraints(for: scrollView)
        deactivateConstraints(for: self)
        self.layoutSubtreeIfNeeded()
    }
    
    func videoViewBase() {
        addSubview(scrollView)
        scrollView.anchors(
            top: topAnchor,
            leading: leadingAnchor,
            bottom: bottomAnchor,
            trailing: trailingAnchor)
        setupVideoView()
    }
    
    private func setupVideoView() {
        addVideoSubviews()
        setupVideoConstraints()
    }
    
    private func addVideoSubviews() {
        guard let documentView = scrollView.documentView else { return }
        documentView.addSubview(statusLabel)
        documentView.addSubview(controlsStack)
        documentView.addSubview(calleeLabel)
        
        // Add buttons to stacks
        controlsStack.addArrangedSubview(muteVideoButton)
        controlsStack.addArrangedSubview(muteAudioButton)
        controlsStack.addArrangedSubview(endButton)
        
        muteVideoButton.anchors(width: 35, height: 35)
        muteAudioButton.anchors(width: 35, height: 35)
        endButton.anchors(width: 35, height: 35)
    }
    
    private func setupVideoConstraints() {
        guard let documentView = scrollView.documentView else { return }
        // Use your custom anchors method for layout
        let statusLabelSize = statusLabel.sizeThatFits(.init(width: .greatestFiniteMagnitude, height: statusLabel.frame.size.height))
        statusLabel.anchors(
            top: documentView.topAnchor,
            centerX: documentView.centerXAnchor,
            paddingTop: 20,
            width: statusLabelSize.width,
            height: statusLabelSize.height)
        
        controlsStack.anchors(
            bottom: documentView.bottomAnchor,
            trailing: documentView.trailingAnchor,
            paddingBottom: 20,
            paddingTrailing: 20,
            width: 150,
            height: 40)
        
        calleeLabel.anchors(
            leading: documentView.leadingAnchor,
            bottom: documentView.bottomAnchor,
            paddingLeading: 30,
            paddingBottom: 30,
            width: 150,
            height: 40)
    }
    
    enum CallTypeState {
        case base, video, voice
    }
    
    func deactivateConstraints(for view: NSView) {
        for constraint in view.constraints {
            if constraint.isActive {
                constraint.isActive = false
            }
        }
    }
    
    func createVoiceView() async {
        if let voiceImageData = voiceImageData, let voiceImage = NSImage(data: voiceImageData), let circleImage = voiceImage.circularImage(size: CGSize(width: 50, height: 50), borderWidth: 5, borderColor: .blue) {
            calleeProfileImageView = NSImageView(image: circleImage)
        } else if let voiceImage = NSImage(named: "Nudge") {
            calleeProfileImageView = NSImageView(image: voiceImage)
        }
        
        if let calleeImageView = calleeProfileImageView {
            addSubview(calleeImageView)
            addSubview(calleeLabel)
            calleeImageView.anchors(
                top: topAnchor,
                leading: leadingAnchor,
                paddingTop: 10,
                paddingLeading: 10,
                width: 50,
                height: 50)
            
            calleeLabel.anchors(
                top: calleeImageView.bottomAnchor,
                leading: leadingAnchor,
                paddingLeading: 20,
                width: 150,
                height: 20)
        }
        
        addSubview(statusLabel)
        addSubview(controlsStack)
        
        
        // Add buttons to stacks
        controlsStack.addArrangedSubview(muteAudioButton)
        controlsStack.addArrangedSubview(endButton)
        
        muteAudioButton.anchors(width: 35, height: 35)
        endButton.anchors(width: 35, height: 35)
        
        let statusLabelSize = statusLabel.sizeThatFits(.init(width: .greatestFiniteMagnitude, height: statusLabel.frame.size.height))
        
        statusLabel.anchors(
            top: topAnchor,
            centerX: centerXAnchor,
            width: statusLabelSize.width,
            height: statusLabelSize.height)
        
        controlsStack.anchors(
            bottom: bottomAnchor,
            trailing: trailingAnchor,
            paddingBottom: 20,
            paddingTrailing: 20,
            width: 125,
            height: 40)
        self.layoutSubtreeIfNeeded()
    }
    
    func addConnectedLocalVideoView(view: NTMTKView) async {
        guard let documentView = scrollView.documentView else { return }
        documentView.addSubview(view)
        updateLocalVideoSize(isConnected: true, view: view)
        self.layoutSubtreeIfNeeded()
    }
    
    deinit {
        NeedleTailLogger().log(level: .debug, message: "Memory Reclaimed in VideoView")
    }
    
    func updateLocalVideoSize(isConnected: Bool, view: NTMTKView) {
        let size: CGSize = .init(width: 300, height: 168)
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            await updateVideoConstraints(size: size, isConnected: isConnected, view: view)
        }
    }
    
    func updateVideoConstraints(size: CGSize, isConnected: Bool, view: NTMTKView) async {
        guard let documentView = scrollView.documentView else { return }
        if isConnected {
            view.anchors(
                bottom: documentView.bottomAnchor,
                trailing: documentView.trailingAnchor,
                paddingBottom: 80,
                paddingTrailing: 20,
                width: size.width - 5,
                height: size.height - 5
            )
            
            view.layer?.cornerRadius = 10
            view.layer?.masksToBounds = true
        } else {
            view.anchors(
                top: documentView.topAnchor,
                leading: documentView.leadingAnchor,
                bottom: documentView.bottomAnchor,
                trailing: documentView.trailingAnchor
            )
        }
    }
}
#endif
