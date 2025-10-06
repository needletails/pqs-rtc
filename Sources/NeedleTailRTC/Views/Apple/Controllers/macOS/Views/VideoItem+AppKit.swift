//
//  VideoItem+AppKit.swift
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

class VideoItem: NSCollectionViewItem {

    override func viewDidLoad() {
        super.viewDidLoad()
    }
    
    override func loadView() {
        view = NSView()
        view.enclosingScrollView?.wantsLayer = true
        view.enclosingScrollView?.backgroundColor = .clear
        view.enclosingScrollView?.layer?.backgroundColor = .clear
        
    }
    deinit {
        NeedleTailLogger().log(level: .debug, message: "Memory Reclaimed in VideoItem")
    }
    
    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet {
            //                updateSelectionHighlighting()
        }
    }
    
    override var isSelected: Bool {
        didSet {
            //            updateSelectionHighlighting()
        }
    }
    
    private func updateSelectionHighlighting() {
        if !isViewLoaded {
            return
        }
        
        let showAsHighlighted = (highlightState == .forSelection) ||
        (isSelected && highlightState != .forDeselection) ||
        (highlightState == .asDropTarget)
        
        textField?.textColor = showAsHighlighted ? .selectedControlTextColor : .labelColor
        view.layer?.backgroundColor = showAsHighlighted ? NSColor.selectedControlColor.cgColor : nil
    }
}
#endif
