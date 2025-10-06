//
//  CollectionViewSections.swift
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

import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

#if os(iOS) || os(macOS)

/// A utility struct that provides collection view layout sections for video conferencing UI.
/// 
/// This struct contains predefined layout configurations for different video conferencing scenarios,
/// including full-screen video display and multi-participant conference views.
@MainActor
public struct CollectionViewSections {
    
    // MARK: - Constants
    
    /// Default aspect ratio for video content (16:9)
    private static let defaultAspectRatio: CGFloat = 16.0 / 9.0
    
    /// Default content insets for conference view items
    private static let defaultContentInsets = NSDirectionalEdgeInsets(
        top: 15,
        leading: 15,
        bottom: 15,
        trailing: 15
    )
    
    // MARK: - Initialization
    
    /// Creates a new instance of CollectionViewSections
    public init() {}
    
    // MARK: - Layout Sections
    
    /// Creates a full-screen layout section for single video display.
    /// 
    /// - Returns: A collection layout section configured for full-screen video display
    /// - Note: On iOS, this creates a true full-screen layout. On macOS, it maintains a 16:9 aspect ratio.
    public func fullScreenItem() -> NSCollectionLayoutSection {
        #if os(iOS)
        return createFullScreenLayout()
        #elseif os(macOS)
        return createAspectRatioLayout(aspectRatio: Self.defaultAspectRatio)
        #endif
    }
    
    /// Creates a full-screen layout section with a custom aspect ratio.
    /// 
    /// - Parameter aspectRatio: The desired aspect ratio (width / height)
    /// - Returns: A collection layout section configured for full-screen video display
    /// - Note: This method is primarily used on macOS to maintain consistent video proportions
    public func fullScreenItem(aspectRatio: CGFloat) -> NSCollectionLayoutSection {
        guard aspectRatio > 0 else {
            assertionFailure("Aspect ratio must be greater than 0")
            return createAspectRatioLayout(aspectRatio: Self.defaultAspectRatio)
        }
        
        return createAspectRatioLayout(aspectRatio: aspectRatio)
    }
    
    /// Creates a conference view layout section for multiple video participants.
    /// 
    /// - Parameter itemCount: The number of video items to display in the conference view
    /// - Returns: A collection layout section configured for multi-participant conference display
    /// - Note: The layout automatically adjusts item sizes based on the participant count
    public func conferenceViewSection(itemCount: Int) -> NSCollectionLayoutSection {
        guard itemCount > 0 else {
            assertionFailure("Item count must be greater than 0")
            return createSingleItemLayout()
        }
        
        return createConferenceLayout(itemCount: itemCount)
    }
    
    /// Creates a conference view layout section with custom content insets.
    /// 
    /// - Parameters:
    ///   - itemCount: The number of video items to display in the conference view
    ///   - contentInsets: Custom content insets for the video items
    /// - Returns: A collection layout section configured for multi-participant conference display
    public func conferenceViewSection(
        itemCount: Int,
        contentInsets: NSDirectionalEdgeInsets
    ) -> NSCollectionLayoutSection {
        guard itemCount > 0 else {
            assertionFailure("Item count must be greater than 0")
            return createSingleItemLayout()
        }
        
        return createConferenceLayout(itemCount: itemCount, contentInsets: contentInsets)
    }
    
    // MARK: - Private Helper Methods
    
    #if os(iOS)
    private func createFullScreenLayout() -> NSCollectionLayoutSection {
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .fractionalHeight(1.0)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1.0),
                heightDimension: .fractionalHeight(1.0)
            ),
            subitems: [item]
        )
        
        return NSCollectionLayoutSection(group: group)
    }
    #endif
    
    private func createAspectRatioLayout(aspectRatio: CGFloat) -> NSCollectionLayoutSection {
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .fractionalWidth(1.0 / aspectRatio)
        )
        
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1.0),
                heightDimension: .fractionalWidth(1.0 / aspectRatio)
            ),
            subitems: [item]
        )
        
        return NSCollectionLayoutSection(group: group)
    }
    
    private func createConferenceLayout(
        itemCount: Int,
        contentInsets: NSDirectionalEdgeInsets = defaultContentInsets
    ) -> NSCollectionLayoutSection {
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0 / CGFloat(itemCount)),
            heightDimension: .fractionalHeight(1.0)
        )
        
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        item.contentInsets = contentInsets
        
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1.0),
                heightDimension: .fractionalHeight(1.0)
            ),
            subitems: [item]
        )
        
        return NSCollectionLayoutSection(group: group)
    }
    
    private func createSingleItemLayout() -> NSCollectionLayoutSection {
        return fullScreenItem()
    }
}
#endif
