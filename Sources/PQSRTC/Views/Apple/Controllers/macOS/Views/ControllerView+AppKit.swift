//
//  ControllerView+AppKit.swift
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

#if os(macOS)
import AppKit
import NeedleTailLogger

@MainActor
/// Root AppKit view that hosts the macOS in-call UI.
///
/// `ControllerView` owns the scrollable video layout (`VideoCallScrollView`) and lightweight
/// overlay labels (callee/status). It also provides helper methods for switching between
/// voice-style and video-style layouts.
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

    /// Creates a tappable/hoverable symbol-image view used as a button.
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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        
    }
    
    /// Removes subviews and clears layout constraints owned by this view.
    func tearDownView() {
        scrollView.removeFromSuperview()
        calleeProfileImageView?.removeFromSuperview()
        statusLabel.removeFromSuperview()
        calleeLabel.removeFromSuperview()
        voiceImageData = nil
        calleeProfileImageView = nil
        deactivateConstraints(for: statusLabel)
        deactivateConstraints(for: calleeLabel)
        if let calleeProfileImageView {
            deactivateConstraints(for: calleeProfileImageView)
        }
        deactivateConstraints(for: scrollView)
        deactivateConstraints(for: self)
        self.layoutSubtreeIfNeeded()
    }
    
    /// Builds the base video layout (scroll view + overlays) used for video calls.
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
        documentView.addSubview(calleeLabel)
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

        calleeLabel.anchors(
            leading: documentView.leadingAnchor,
            bottom: documentView.bottomAnchor,
            paddingLeading: 30,
            paddingBottom: 30,
            width: 150,
            height: 40)
    }
    
    /// High-level call UI layout mode.
    enum CallTypeState {
        case base, video, voice
    }
    
    /// Deactivates all constraints currently attached to the given view.
    func deactivateConstraints(for view: NSView) {
        for constraint in view.constraints {
            if constraint.isActive {
                constraint.isActive = false
            }
        }
    }
    
    /// Builds the “voice call” layout (avatar + labels).
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

        let statusLabelSize = statusLabel.sizeThatFits(.init(width: .greatestFiniteMagnitude, height: statusLabel.frame.size.height))
        
        statusLabel.anchors(
            top: topAnchor,
            centerX: centerXAnchor,
            width: statusLabelSize.width,
            height: statusLabelSize.height)
        
        self.layoutSubtreeIfNeeded()
    }
    
    /// Adds the local video preview tile once the call is connected.
    func addConnectedLocalVideoView(view: NTMTKView) async {
        guard let documentView = scrollView.documentView else { return }
        documentView.addSubview(view)
        updateLocalVideoSize(isConnected: true, view: view)
        self.layoutSubtreeIfNeeded()
    }
    
    deinit {
        NeedleTailLogger().log(level: .debug, message: "Memory Reclaimed in VideoView")
    }
    
    /// Updates the local video tile size and layout mode.
    func updateLocalVideoSize(isConnected: Bool, view: NTMTKView) {
        let size: CGSize = .init(width: 300, height: 168)
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            await updateVideoConstraints(size: size, isConnected: isConnected, view: view)
        }
    }
    
    /// Applies layout constraints to the provided video view for the current call state.
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
