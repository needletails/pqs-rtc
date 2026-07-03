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

/// Uses a top-left origin so `frame`/`bounds` match NSEvent translation and iOS-style edge math.
final class FlippedPreviewOverlayView: NSView {
    override var isFlipped: Bool { true }
}

/// Root AppKit view that hosts the macOS in-call UI.
///
/// `ControllerView` owns the scrollable video layout (`VideoCallScrollView`) and lightweight
/// overlay labels (callee/status). It also provides helper methods for switching between
/// voice-style and video-style layouts.
@MainActor
class ControllerView: NSView {
    
    private let pipLayoutLog = NeedleTailLogger("[ControllerView-PiP]")
    
    let scrollView = VideoCallScrollView()
    let localPreviewOverlay = FlippedPreviewOverlayView()
    /// Voice/video window sizing applied to the call root; must be replaced—not stacked—on each transition.
    private var callRootSizingConstraints: [NSLayoutConstraint] = []
    private weak var currentPreviewView: NTMTKView?
    private var previewOverlayConstraints: [NSLayoutConstraint] = []
    private var previewTopConstraint: NSLayoutConstraint?
    private var previewTrailingConstraint: NSLayoutConstraint?
    private var previewWidthConstraint: NSLayoutConstraint?
    private var previewHeightConstraint: NSLayoutConstraint?
    private let connectedPreviewCornerRadius: CGFloat = 16
    
    /// Hosts caller name + status above the scroll view so labels are not clipped by the collection view.
    private let callInfoChrome: NSVisualEffectView = {
        let v = NSVisualEffectView()
        v.wantsLayer = true
        v.material = .hudWindow
        v.blendingMode = .withinWindow
        v.state = .active
        v.layer?.cornerRadius = 18
        v.layer?.cornerCurve = .continuous
        v.layer?.masksToBounds = true
        v.layer?.borderWidth = 1
        v.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        v.layer?.shadowColor = NSColor.black.cgColor
        v.layer?.shadowOpacity = 0.22
        v.layer?.shadowRadius = 20
        v.layer?.shadowOffset = .init(width: 0, height: -4)
        v.layer?.zPosition = 900
        return v
    }()
    var voiceImageData: Data?
    var calleeProfileImageView: NSImageView?
    
    let calleeLabel: NSTextField = {
        let txt = NSTextField.newLabel()
        txt.textColor = Constants.OFF_WHITE_COLOR
        txt.backgroundColor = .clear
        txt.drawsBackground = false
        txt.font = .systemFont(ofSize: 14, weight: .semibold)
        txt.alignment = .center
        txt.lineBreakMode = .byTruncatingTail
        txt.maximumNumberOfLines = 2
        txt.cell?.wraps = true
        txt.cell?.isScrollable = false
        txt.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return txt
    }()
    
    let statusLabel: NSTextField = {
        let txt = NSTextField.newLabel()
        txt.textColor = NSColor.white.withAlphaComponent(0.78)
        txt.backgroundColor = .clear
        txt.drawsBackground = false
        txt.font = .systemFont(ofSize: 12, weight: .medium)
        txt.alignment = .center
        txt.lineBreakMode = .byTruncatingTail
        txt.maximumNumberOfLines = 2
        txt.cell?.wraps = true
        txt.cell?.isScrollable = false
        txt.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
    
    override func layout() {
        super.layout()
        bringLocalPreviewOverlayToFront()
        if let currentPreviewView {
            let isConnectedPreviewLayout = currentPreviewView.superview === localPreviewOverlay
                && previewOverlayConstraints.contains(where: \.isActive)
            applyLocalPreviewCornerStyle(isConnected: isConnectedPreviewLayout, to: currentPreviewView)
        }
    }
    
    /// Keeps the PiP overlay above the scroll view, collection churn, and any full-screen
    /// hosting views (e.g. SwiftUI call controls) added after `videoViewBase()`.
    func bringLocalPreviewOverlayToFront() {
        guard localPreviewOverlay.superview === self else { return }
        addSubview(localPreviewOverlay, positioned: .above, relativeTo: nil)
    }
    
    /// Replaces fixed width/height used for the compact voice-call chrome (stacks constraints if repeated).
    func replaceCallRootSizingForVoiceCall(width: CGFloat, height: CGFloat) {
        NSLayoutConstraint.deactivate(callRootSizingConstraints)
        callRootSizingConstraints.removeAll()
        translatesAutoresizingMaskIntoConstraints = false
        let w = widthAnchor.constraint(equalToConstant: width)
        let h = heightAnchor.constraint(equalToConstant: height)
        w.priority = .required
        h.priority = .required
        NSLayoutConstraint.activate([w, h])
        callRootSizingConstraints = [w, h]
    }
    
    /// Replaces minimum size hints for video calls (matches ``VideoCallViewController`` `passSize` defaults).
    func replaceCallRootSizingForVideoCall(minWidth: CGFloat, minHeight: CGFloat) {
        NSLayoutConstraint.deactivate(callRootSizingConstraints)
        callRootSizingConstraints.removeAll()
        translatesAutoresizingMaskIntoConstraints = false
        let w = widthAnchor.constraint(greaterThanOrEqualToConstant: minWidth)
        let h = heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight)
        w.priority = .required
        h.priority = .required
        NSLayoutConstraint.activate([w, h])
        callRootSizingConstraints = [w, h]
    }
    
    func clearCallRootSizingConstraints() {
        NSLayoutConstraint.deactivate(callRootSizingConstraints)
        callRootSizingConstraints.removeAll()
    }
    
    /// Removes subviews and clears layout constraints owned by this view.
    func tearDownView() {
        clearCallRootSizingConstraints()
        scrollView.removeFromSuperview()
        localPreviewOverlay.removeFromSuperview()
        callInfoChrome.removeFromSuperview()
        calleeProfileImageView?.removeFromSuperview()
        statusLabel.removeFromSuperview()
        calleeLabel.removeFromSuperview()
        voiceImageData = nil
        calleeProfileImageView = nil
        deactivateConstraints(for: statusLabel)
        deactivateConstraints(for: calleeLabel)
        deactivateConstraints(for: callInfoChrome)
        if let calleeProfileImageView {
            deactivateConstraints(for: calleeProfileImageView)
        }
        deactivateConstraints(for: localPreviewOverlay)
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
        
        localPreviewOverlay.wantsLayer = true
        localPreviewOverlay.layer?.backgroundColor = NSColor.clear.cgColor
        localPreviewOverlay.layer?.zPosition = 1000
        addSubview(localPreviewOverlay, positioned: .above, relativeTo: scrollView)
        localPreviewOverlay.anchors(
            top: topAnchor,
            leading: leadingAnchor,
            bottom: bottomAnchor,
            trailing: trailingAnchor)
        setupVideoView()
    }
    
    private func setupVideoView() {
        installCallInfoChrome()
    }
    
    func setCallInfoChromeHidden(_ hidden: Bool) {
        callInfoChrome.isHidden = hidden
        calleeLabel.isHidden = hidden
        statusLabel.isHidden = hidden
    }
    
    /// Pins name + status in a top-center card on the root view (not inside the collection document view).
    private func installCallInfoChrome() {
        calleeLabel.removeFromSuperview()
        statusLabel.removeFromSuperview()
        callInfoChrome.removeFromSuperview()
        
        addSubview(callInfoChrome, positioned: .above, relativeTo: scrollView)
        if #available(macOS 11.0, *) {
            callInfoChrome.anchors(
                top: safeAreaLayoutGuide.topAnchor,
                centerX: centerXAnchor,
                paddingTop: 8,
                leadingAtLeast: leadingAnchor,
                paddingLeadingMin: 16,
                trailingAtMost: trailingAnchor,
                paddingTrailingMax: 16,
                lessThanEqualToWidth: 260)
        } else {
            callInfoChrome.anchors(
                top: topAnchor,
                centerX: centerXAnchor,
                paddingTop: 16,
                leadingAtLeast: leadingAnchor,
                paddingLeadingMin: 16,
                trailingAtMost: trailingAnchor,
                paddingTrailingMax: 16,
                lessThanEqualToWidth: 260)
        }
        
        callInfoChrome.addSubview(calleeLabel)
        callInfoChrome.addSubview(statusLabel)
        calleeLabel.anchors(
            top: callInfoChrome.topAnchor,
            leading: callInfoChrome.leadingAnchor,
            trailing: callInfoChrome.trailingAnchor,
            paddingTop: 10,
            paddingLeading: 12,
            paddingTrailing: 12)
        statusLabel.anchors(
            top: calleeLabel.bottomAnchor,
            leading: callInfoChrome.leadingAnchor,
            bottom: callInfoChrome.bottomAnchor,
            trailing: callInfoChrome.trailingAnchor,
            paddingTop: 4,
            paddingLeading: 12,
            paddingBottom: 10,
            paddingTrailing: 12)
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

    /// Clears stored PiP overlay constraints when the preview leaves the overlay.
    func clearPreviewOverlayConstraints(for view: NTMTKView) {
        guard view === currentPreviewView || view.superview === localPreviewOverlay else { return }
        NSLayoutConstraint.deactivate(previewOverlayConstraints)
        previewOverlayConstraints = []
        previewTopConstraint = nil
        previewTrailingConstraint = nil
        previewWidthConstraint = nil
        previewHeightConstraint = nil
        if currentPreviewView === view {
            currentPreviewView = nil
        }
    }

    /// Strips stale layout constraints before mounting a video tile into a collection cell.
    ///
    /// PiP width/height constraints (160×90) must not coexist with fill-to-cell edge pins.
    func prepareVideoViewForCollectionCellLayout(_ videoView: NTMTKView, hostView: NSView) {
        clearPreviewOverlayConstraints(for: videoView)
        if let superview = videoView.superview, superview !== hostView {
            deactivateConstraintsReferencing(videoView, in: superview)
        }
        deactivateConstraintsReferencing(videoView, in: hostView)
        deactivateConstraints(for: videoView)
        videoView.translatesAutoresizingMaskIntoConstraints = false
        videoView.autoresizingMask = []
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
    func addConnectedLocalVideoView(view: NTMTKView) {
        bringLocalPreviewOverlayToFront()
        if let superview = view.superview, superview !== localPreviewOverlay {
            deactivateConstraintsReferencing(view, in: superview)
            view.removeFromSuperview()
        }
        // Re-add without removing first: keeps Auto Layout constraints intact. Removing here used to
        // deactivate top/trailing to the overlay while stale handles remained in `previewOverlayConstraints`.
        localPreviewOverlay.addSubview(view, positioned: .above, relativeTo: nil)
        localPreviewOverlay.isHidden = false
        localPreviewOverlay.alphaValue = 1
        // Clear AppKit default translating masks so PiP width/height constraints are not broken by
        // implicit “stick to superview” sizing (symptom: huge view hugging the trailing edge).
        view.translatesAutoresizingMaskIntoConstraints = false
        view.autoresizingMask = []
        view.wantsLayer = true
        view.layer?.zPosition = 1001
        view.isHidden = false
        view.alphaValue = 1
        applyConnectedLocalPreviewCornerStyle(to: view)
        pipLayoutLog.log(
            level: .info,
            message: "addConnectedLocalVideoView context=\(view.contextName) tam=\(view.translatesAutoresizingMaskIntoConstraints) mask=\(view.autoresizingMask.rawValue) overlayBounds=\(String(describing: localPreviewOverlay.bounds.size))"
        )
        updateLocalVideoSize(isConnected: true, view: view)
        schedulePiPLayoutCommit()
    }
    
    deinit {
        NeedleTailLogger().log(level: .debug, message: "Memory Reclaimed in VideoView")
    }
    
    /// Updates the local video tile size and layout mode.
    func updateLocalVideoSize(isConnected: Bool, view: NTMTKView, minimize: Bool = false, animated: Bool = true) {
        let size = previewSize(minimized: minimize)
        updateVideoConstraints(size: size, isConnected: isConnected, view: view, animated: animated)
    }
    
    /// Applies layout constraints to the provided video view for the current call state.
    func updateVideoConstraints(size: CGSize, isConnected: Bool, view: NTMTKView, animated: Bool = true) {
        let targetW = max(1, size.width)
        let targetH = max(1, size.height)
        pipLayoutLog.log(
            level: .info,
            message: "updateVideoConstraints enter context=\(view.contextName) isConnected=\(isConnected) targetSize=\(targetW)x\(targetH) superview=\(String(describing: type(of: view.superview))) tam=\(view.translatesAutoresizingMaskIntoConstraints) mask=\(view.autoresizingMask.rawValue) overlay=\(view.superview === localPreviewOverlay) currentPreviewSame=\(currentPreviewView === view)"
        )
        
        if isConnected,
           currentPreviewView === view,
           view.superview === localPreviewOverlay,
           let top = previewTopConstraint,
           let trailing = previewTrailingConstraint,
           let widthC = previewWidthConstraint,
           let heightC = previewHeightConstraint,
           top.isActive, trailing.isActive, widthC.isActive, heightC.isActive {
            let w = targetW
            let h = targetH
            pipLayoutLog.log(
                level: .info,
                message: "updateVideoConstraints fastPath before top=\(top.constant) trail=\(trailing.constant) w=\(widthC.constant) h=\(heightC.constant) active=[\(top.isActive),\(trailing.isActive),\(widthC.isActive),\(heightC.isActive)]"
            )
            if widthC.constant != w { widthC.constant = w }
            if heightC.constant != h { heightC.constant = h }
            if animated, window != nil {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    self.localPreviewOverlay.layoutSubtreeIfNeeded()
                    self.layoutSubtreeIfNeeded()
                    self.applyLocalPreviewCornerStyle(isConnected: true, to: view)
                }
            } else {
                schedulePiPLayoutCommit()
            }
            applyLocalPreviewCornerStyle(isConnected: true, to: view)
            logPiPLayoutSnapshot(phase: "fastPathAfter", view: view)
            return
        }
        
        if isConnected {
            var skipReasons: [String] = []
            if currentPreviewView !== view { skipReasons.append("currentPreviewMismatch(current=\(String(describing: currentPreviewView?.contextName)) view=\(view.contextName))") }
            if view.superview !== localPreviewOverlay { skipReasons.append("superviewNotOverlay") }
            if previewTopConstraint == nil { skipReasons.append("nilTop") }
            if previewTrailingConstraint == nil { skipReasons.append("nilTrailing") }
            if previewWidthConstraint == nil { skipReasons.append("nilWidth") }
            if previewHeightConstraint == nil { skipReasons.append("nilHeight") }
            if let t = previewTopConstraint, !t.isActive { skipReasons.append("topInactive") }
            if let t = previewTrailingConstraint, !t.isActive { skipReasons.append("trailingInactive") }
            if let t = previewWidthConstraint, !t.isActive { skipReasons.append("widthInactive") }
            if let t = previewHeightConstraint, !t.isActive { skipReasons.append("heightInactive") }
            pipLayoutLog.log(level: .info, message: "updateVideoConstraints fullLayoutPath reasons=\(skipReasons.joined(separator: "; ")) storedCount=\(previewOverlayConstraints.count) storedAllActive=\(previewOverlayConstraints.allSatisfy(\.isActive))")
        }
        
        if let superview = view.superview {
            let beforeOverlay = localPreviewOverlay.constraints.filter {
                ($0.firstItem as AnyObject?) === view || ($0.secondItem as AnyObject?) === view
            }.count
            deactivateConstraintsReferencing(view, in: superview)
            let afterOverlay = localPreviewOverlay.constraints.filter {
                ($0.firstItem as AnyObject?) === view || ($0.secondItem as AnyObject?) === view
            }.count
            pipLayoutLog.log(level: .info, message: "updateVideoConstraints stripped superview constraints involving view: before=\(beforeOverlay) after=\(afterOverlay) super=\(String(describing: type(of: superview)))")
        }
        let ownedBefore = view.constraints.filter(\.isActive).count
        deactivateConstraints(for: view)
        let ownedAfter = view.constraints.filter(\.isActive).count
        pipLayoutLog.log(level: .info, message: "updateVideoConstraints view.ownedConstraints active: \(ownedBefore) -> \(ownedAfter)")
        if isConnected {
            view.translatesAutoresizingMaskIntoConstraints = false
            let previewConstraintsValid = !previewOverlayConstraints.isEmpty
                && previewOverlayConstraints.allSatisfy(\.isActive)
            if currentPreviewView !== view || view.superview !== localPreviewOverlay || !previewConstraintsValid {
                NSLayoutConstraint.deactivate(previewOverlayConstraints)
                previewOverlayConstraints = []
                previewTopConstraint = nil
                previewTrailingConstraint = nil
                previewWidthConstraint = nil
                previewHeightConstraint = nil
                currentPreviewView = view
                pipLayoutLog.log(level: .info, message: "updateVideoConstraints reset stored PiP constraints validBeforeReset=\(previewConstraintsValid) inOverlay=\(view.superview === localPreviewOverlay)")
            }
            if previewOverlayConstraints.isEmpty {
                let top = view.topAnchor.constraint(equalTo: localPreviewOverlay.topAnchor, constant: 16)
                let trailing = view.trailingAnchor.constraint(equalTo: localPreviewOverlay.trailingAnchor, constant: -16)
                let width = view.widthAnchor.constraint(equalToConstant: targetW)
                let height = view.heightAnchor.constraint(equalToConstant: targetH)
                width.priority = .required
                height.priority = .required
                previewTopConstraint = top
                previewTrailingConstraint = trailing
                previewWidthConstraint = width
                previewHeightConstraint = height
                previewOverlayConstraints = [top, trailing, width, height]
                NSLayoutConstraint.activate(previewOverlayConstraints)
                view.invalidateIntrinsicContentSize()
                pipLayoutLog.log(
                    level: .info,
                    message: "updateVideoConstraints activated PiP top=\(top.constant) trail=\(trailing.constant) w=\(width.constant) h=\(height.constant) priW=\(width.priority.rawValue) priH=\(height.priority.rawValue)"
                )
            } else {
                previewWidthConstraint?.constant = targetW
                previewHeightConstraint?.constant = targetH
                pipLayoutLog.log(
                    level: .info,
                    message: "updateVideoConstraints updated existing PiP w=\(previewWidthConstraint?.constant ?? -1) h=\(previewHeightConstraint?.constant ?? -1)"
                )
            }
            applyLocalPreviewCornerStyle(isConnected: true, to: view)
        } else {
            pipLayoutLog.log(level: .info, message: "updateVideoConstraints disconnected → pin to documentView fill")
            NSLayoutConstraint.deactivate(previewOverlayConstraints)
            guard let documentView = scrollView.documentView else { return }
            view.anchors(
                top: documentView.topAnchor,
                leading: documentView.leadingAnchor,
                bottom: documentView.bottomAnchor,
                trailing: documentView.trailingAnchor)
            applyLocalPreviewCornerStyle(isConnected: false, to: view)
        }
        
        if animated, window != nil {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.localPreviewOverlay.layoutSubtreeIfNeeded()
                self.layoutSubtreeIfNeeded()
                self.applyLocalPreviewCornerStyle(isConnected: isConnected, to: view)
            }
        } else {
            schedulePiPLayoutCommit()
        }
        applyLocalPreviewCornerStyle(isConnected: isConnected, to: view)
        if isConnected, view.superview === localPreviewOverlay {
            logPiPLayoutSnapshot(phase: "fullPathEnd", view: view)
        }
    }

    func applyConnectedLocalPreviewCornerStyle(to view: NTMTKView) {
        applyLocalPreviewCornerStyle(isConnected: true, to: view)
    }

    private func applyLocalPreviewCornerStyle(isConnected: Bool, to view: NTMTKView) {
        let radius = isConnected ? connectedPreviewCornerRadius : 0
        view.wantsLayer = true
        view.layer?.cornerRadius = radius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = isConnected
        view.layer?.shadowOpacity = 0

        guard let captureView = view.captureView else { return }
        captureView.wantsLayer = true
        captureView.layer?.cornerRadius = radius
        captureView.layer?.cornerCurve = .continuous
        captureView.layer?.masksToBounds = isConnected

        if let previewCaptureView = captureView as? PreviewCaptureView {
            previewCaptureView.previewLayer.cornerRadius = radius
            previewCaptureView.previewLayer.masksToBounds = isConnected
        }
    }
    
    /// Commits overlay/root layout on the next main run loop tick to avoid calling
    /// `layoutSubtreeIfNeeded` while AppKit is already in `-layout` (recursion warning).
    private func schedulePiPLayoutCommit() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.localPreviewOverlay.layoutSubtreeIfNeeded()
            self.layoutSubtreeIfNeeded()
        }
    }
    
    /// Debug snapshot after PiP constraint passes (filter logs with `[ControllerView+PiP]`).
    private func logPiPLayoutSnapshot(phase: String, view: NTMTKView) {
        let hz = view.constraintsAffectingLayout(for: .horizontal).count
        let vt = view.constraintsAffectingLayout(for: .vertical).count
        let amb = view.hasAmbiguousLayout
        let intrinsic = view.intrinsicContentSize
        let captureFrame = view.captureView?.frame.size ?? .zero
        let captureBounds = view.captureView?.bounds.size ?? .zero
        let captureSuperview = view.captureView?.superview.map { String(describing: type(of: $0)) } ?? "nil"
        let previewLayerFrame: CGSize
        let previewLayerGravity: String
        if let previewCaptureView = view.captureView as? PreviewCaptureView {
            previewLayerFrame = previewCaptureView.previewLayer.frame.size
            previewLayerGravity = String(describing: previewCaptureView.previewLayer.videoGravity)
        } else {
            previewLayerFrame = .zero
            previewLayerGravity = "n/a"
        }
        pipLayoutLog.log(
            level: .info,
            message: "\(phase) frame=\(view.frame.size) bounds=\(view.bounds.size) overlay=\(localPreviewOverlay.bounds.size) captureFrame=\(captureFrame) captureBounds=\(captureBounds) captureSuperview=\(captureSuperview) previewLayerFrame=\(previewLayerFrame) previewGravity=\(previewLayerGravity) ambiguous=\(amb) intrinsic=\(intrinsic.width)x\(intrinsic.height) affectingLayout H=\(hz) V=\(vt) top=\(previewTopConstraint?.constant ?? .nan) trail=\(previewTrailingConstraint?.constant ?? .nan) wC=\(previewWidthConstraint?.constant ?? .nan) hC=\(previewHeightConstraint?.constant ?? .nan) wActive=\(previewWidthConstraint?.isActive ?? false) hActive=\(previewHeightConstraint?.isActive ?? false)"
        )
    }
    
    func moveLocalPreview(by translation: CGPoint, view: NTMTKView) {
        guard currentPreviewView === view,
              let top = previewTopConstraint,
              let trailing = previewTrailingConstraint
        else { return }
        let overlayBounds = localPreviewOverlay.bounds
        guard overlayBounds.width > 0, overlayBounds.height > 0 else { return }
        
        let currentFrame = view.frame
        let proposedMinX = currentFrame.minX + translation.x
        let proposedMinY = currentFrame.minY + translation.y
        let maxMinX = max(16, overlayBounds.width - currentFrame.width - 16)
        let maxMinY = max(16, overlayBounds.height - currentFrame.height - 16)
        let clampedMinX = min(max(16, proposedMinX), maxMinX)
        let clampedMinY = min(max(16, proposedMinY), maxMinY)
        // trailing: view.trailing == overlay.trailing + constant → constant must be *negative* to sit inside.
        let insetFromRight = overlayBounds.width - clampedMinX - currentFrame.width
        top.constant = clampedMinY
        trailing.constant = -max(16, insetFromRight)
        schedulePiPLayoutCommit()
    }
    
    func snapLocalPreviewToNearestCorner(view: NTMTKView, animated: Bool = true) {
        guard currentPreviewView === view,
              let top = previewTopConstraint,
              let trailing = previewTrailingConstraint
        else { return }
        let overlayBounds = localPreviewOverlay.bounds
        guard overlayBounds.width > 0, overlayBounds.height > 0 else { return }
        
        let frame = view.frame
        let leftX: CGFloat = 16
        let rightX = max(16, overlayBounds.width - frame.width - 16)
        let topY: CGFloat = 16
        let bottomY = max(16, overlayBounds.height - frame.height - 16)
        let currentCenter = CGPoint(x: frame.midX, y: frame.midY)
        let cornerOrigins: [(CGFloat, CGFloat)] = [
            (leftX, topY), (rightX, topY),
            (leftX, bottomY), (rightX, bottomY)
        ]
        let bestOrigin = cornerOrigins.min { a, b in
            let ca = CGPoint(x: a.0 + frame.width / 2, y: a.1 + frame.height / 2)
            let cb = CGPoint(x: b.0 + frame.width / 2, y: b.1 + frame.height / 2)
            return hypot(ca.x - currentCenter.x, ca.y - currentCenter.y) < hypot(cb.x - currentCenter.x, cb.y - currentCenter.y)
        } ?? (leftX, topY)
        let insetFromRight = overlayBounds.width - bestOrigin.0 - frame.width
        top.constant = bestOrigin.1
        trailing.constant = -max(16, insetFromRight)
        
        if animated, window != nil {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.localPreviewOverlay.layoutSubtreeIfNeeded()
                self.layoutSubtreeIfNeeded()
            }
        } else {
            schedulePiPLayoutCommit()
        }
    }
    
    private func previewSize(minimized: Bool) -> CGSize {
        // Use an explicit FaceTime-style PiP size so the local preview stays compact
        // and does not grow with the call window.
        if minimized {
            return CGSize(width: 112, height: 63)
        } else {
            return CGSize(width: 160, height: 90)
        }
    }
    
    private func deactivateConstraintsReferencing(_ view: NSView, in container: NSView) {
        let constraints = container.constraints.filter {
            ($0.firstItem as AnyObject?) === view || ($0.secondItem as AnyObject?) === view
        }
        for constraint in constraints {
            constraint.isActive = false
            container.removeConstraint(constraint)
        }
    }
}
#endif
