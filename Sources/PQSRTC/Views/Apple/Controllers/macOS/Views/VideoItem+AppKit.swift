//
//  VideoItem+AppKit.swift
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

/// `NSCollectionViewItem` representing a single video tile.
///
/// The macOS call UI uses a collection view to display remote (and sometimes local) video views.
/// This item customizes view setup and provides a place for selection/highlight styling.
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
    
    /// Updates label/background styling based on selection/highlight state.
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
