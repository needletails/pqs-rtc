//
//  CollectionViewSections.swift
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
        // Keep the remote tile pinned to the full collection bounds while the window is resized.
        // Renderer-level videoGravity/scale handles letterboxing; layout should not collapse.
        return createFullScreenLayout()
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
#if os(iOS)
            return createFullScreenLayout()
#elseif os(macOS)
            return createAspectRatioLayout(aspectRatio: Self.defaultAspectRatio)
#endif
        }
#if os(iOS)
        return createFullScreenLayout()
#elseif os(macOS)
        return createAspectRatioLayout(aspectRatio: aspectRatio)
#endif
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
        
        return createConferenceLayout(itemCount: itemCount, groupAbsoluteExtent: nil)
    }
    
    #if os(macOS)
    /// Conference row with a non-zero group extent so items do not collapse when the compositional container is briefly `.zero` during window resize.
    public func conferenceViewSection(itemCount: Int, groupAbsoluteExtent: CGSize) -> NSCollectionLayoutSection {
        guard itemCount > 0 else {
            assertionFailure("Item count must be greater than 0")
            return createSingleItemLayout()
        }
        return createConferenceLayout(itemCount: itemCount, groupAbsoluteExtent: groupAbsoluteExtent)
    }
    #endif
    
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
        
        return createConferenceLayout(itemCount: itemCount, contentInsets: contentInsets, groupAbsoluteExtent: nil)
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
    
    #if os(macOS)
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
    
    private func createFullScreenLayout(groupAbsoluteExtent: CGSize? = nil) -> NSCollectionLayoutSection {
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .fractionalHeight(1.0)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let groupLayoutSize: NSCollectionLayoutSize
        if let g = groupAbsoluteExtent {
            let w = max(1, g.width)
            let h = max(1, g.height)
            groupLayoutSize = NSCollectionLayoutSize(
                widthDimension: .absolute(w),
                heightDimension: .absolute(h)
            )
        } else {
            groupLayoutSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1.0),
                heightDimension: .fractionalHeight(1.0)
            )
        }
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: groupLayoutSize,
            subitems: [item]
        )
        return NSCollectionLayoutSection(group: group)
    }
    
    /// Single-tile layout with explicit group size (macOS VoIP resize / transient zero container).
    public func fullScreenItem(groupAbsoluteExtent: CGSize) -> NSCollectionLayoutSection {
        createFullScreenLayout(groupAbsoluteExtent: groupAbsoluteExtent)
    }
    #endif
    
    private func createConferenceLayout(
        itemCount: Int,
        contentInsets: NSDirectionalEdgeInsets = defaultContentInsets,
        groupAbsoluteExtent: CGSize? = nil
    ) -> NSCollectionLayoutSection {
        #if os(iOS)
        let maxItemsPerPage = 12
        let usesPaging = itemCount > maxItemsPerPage
        let layoutItemCount = min(itemCount, maxItemsPerPage)
        #else
        // Keep macOS non-scrollable for resize stability; do not rely on horizontal paging gestures.
        let usesPaging = false
        let layoutItemCount = itemCount
        #endif

        let grid = conferenceGridDimensions(for: layoutItemCount)
        let tunedInsets = conferenceContentInsets(base: contentInsets, for: layoutItemCount)

        let tileSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .fractionalHeight(1.0)
        )
        let tile = NSCollectionLayoutItem(layoutSize: tileSize)
        tile.contentInsets = tunedInsets

        let rowSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .fractionalHeight(1.0 / CGFloat(grid.rows))
        )
        let rowGroup = NSCollectionLayoutGroup.horizontal(
            layoutSize: rowSize,
            subitem: tile,
            count: grid.columns
        )

        let pageGroupSize: NSCollectionLayoutSize
        if let g = groupAbsoluteExtent {
            let w = max(1, g.width)
            let h = max(1, g.height)
            pageGroupSize = NSCollectionLayoutSize(
                widthDimension: .absolute(w),
                heightDimension: .absolute(h)
            )
        } else {
            pageGroupSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1.0),
                heightDimension: .fractionalHeight(1.0)
            )
        }

        let pageGroup = NSCollectionLayoutGroup.vertical(
            layoutSize: pageGroupSize,
            subitem: rowGroup,
            count: grid.rows
        )

        let section = NSCollectionLayoutSection(group: pageGroup)
        #if os(iOS)
        if usesPaging {
            section.orthogonalScrollingBehavior = .groupPaging
        }
        #endif
        return section
    }

    /// Produces a balanced rows x columns grid for conference tiles.
    private func conferenceGridDimensions(for itemCount: Int) -> (columns: Int, rows: Int) {
        switch itemCount {
        case 1...2:
            return (2, 1)
        case 3...4:
            return (2, 2)
        case 5...6:
            return (3, 2)
        case 7...9:
            return (3, 3)
        case 10...12:
            return (4, 3)
        default:
            // Keep more than 12 participants visible while avoiding ultra-thin single-row tiles.
            return (4, Int(ceil(Double(itemCount) / 4.0)))
        }
    }

    /// Scales default spacing down as participant count grows.
    private func conferenceContentInsets(
        base: NSDirectionalEdgeInsets,
        for itemCount: Int
    ) -> NSDirectionalEdgeInsets {
        let scale: CGFloat
        switch itemCount {
        case ...4:
            scale = 1.0
        case 5...9:
            scale = 0.75
        default:
            scale = 0.5
        }

        return NSDirectionalEdgeInsets(
            top: base.top * scale,
            leading: base.leading * scale,
            bottom: base.bottom * scale,
            trailing: base.trailing * scale
        )
    }
    
    private func createSingleItemLayout() -> NSCollectionLayoutSection {
        return fullScreenItem()
    }

    // MARK: - Screen-share dominant layout

    /// Layout where a single screen-share tile dominates and camera thumbnails stay secondary.
    /// Screen share should feel like the presentation surface, not another equal participant tile.
    ///
    /// - Parameter cameraTileCount: Number of camera tiles in the strip (0 means screen only).
    public func screenShareDominantSection(cameraTileCount: Int) -> NSCollectionLayoutSection {
        return createScreenShareDominantLayout(cameraTileCount: cameraTileCount, groupAbsoluteExtent: nil)
    }

    /// iOS section-provider variant with the current collection view size.
    public func screenShareDominantSection(cameraTileCount: Int, containerSize: CGSize) -> NSCollectionLayoutSection {
        return createScreenShareDominantLayout(cameraTileCount: cameraTileCount, groupAbsoluteExtent: containerSize)
    }

    #if os(macOS)
    /// macOS variant with explicit group extent to avoid zero-bounds during resize.
    public func screenShareDominantSection(cameraTileCount: Int, groupAbsoluteExtent: CGSize) -> NSCollectionLayoutSection {
        return createScreenShareDominantLayout(cameraTileCount: cameraTileCount, groupAbsoluteExtent: groupAbsoluteExtent)
    }
    #endif

    private func createScreenShareDominantLayout(
        cameraTileCount: Int,
        groupAbsoluteExtent: CGSize?
    ) -> NSCollectionLayoutSection {
        func outerLayoutSize(for extent: CGSize?) -> NSCollectionLayoutSize {
            if let extent {
                return NSCollectionLayoutSize(
                    widthDimension: .absolute(max(1, extent.width)),
                    heightDimension: .absolute(max(1, extent.height))
                )
            }
            return NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1.0),
                heightDimension: .fractionalHeight(1.0)
            )
        }

        guard cameraTileCount > 0 else {
            if let g = groupAbsoluteExtent {
                let s = NSCollectionLayoutSize(
                    widthDimension: .absolute(max(1, g.width)),
                    heightDimension: .absolute(max(1, g.height))
                )
                let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1.0),
                    heightDimension: .fractionalHeight(1.0)
                ))
                let group = NSCollectionLayoutGroup.horizontal(layoutSize: s, subitems: [item])
                return NSCollectionLayoutSection(group: group)
            }
            return fullScreenItem()
        }

        let visibleCameraCount = max(1, cameraTileCount)
        let isWide = groupAbsoluteExtent.map { $0.width > max(1, $0.height) * 1.08 } ?? false

        let screenItem = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .fractionalHeight(1.0)
        ))
        screenItem.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 2, bottom: 2, trailing: 2)

        let cameraItem = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .fractionalHeight(1.0)
        ))
        cameraItem.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)

        func cameraGridGroup(columns: Int, rows: Int, layoutSize: NSCollectionLayoutSize) -> NSCollectionLayoutGroup {
            let rowSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1.0),
                heightDimension: .fractionalHeight(1.0 / CGFloat(max(1, rows)))
            )
            let row = NSCollectionLayoutGroup.horizontal(
                layoutSize: rowSize,
                subitem: cameraItem,
                count: max(1, columns)
            )
            return NSCollectionLayoutGroup.vertical(
                layoutSize: layoutSize,
                subitem: row,
                count: max(1, rows)
            )
        }

        let outerSize = outerLayoutSize(for: groupAbsoluteExtent)
        let outerGroup: NSCollectionLayoutGroup
        if isWide {
            let columns = visibleCameraCount <= 2 ? 1 : 2
            let rows = Int(ceil(Double(visibleCameraCount) / Double(columns)))
            let screenFraction: CGFloat = visibleCameraCount <= 2 ? 0.86 : 0.82
            let screenSize: NSCollectionLayoutSize
            let cameraSize: NSCollectionLayoutSize
            if let g = groupAbsoluteExtent {
                screenSize = NSCollectionLayoutSize(
                    widthDimension: .absolute(max(1, g.width * screenFraction)),
                    heightDimension: .absolute(max(1, g.height))
                )
                cameraSize = NSCollectionLayoutSize(
                    widthDimension: .absolute(max(1, g.width * (1.0 - screenFraction))),
                    heightDimension: .absolute(max(1, g.height))
                )
            } else {
                screenSize = NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(screenFraction),
                    heightDimension: .fractionalHeight(1.0)
                )
                cameraSize = NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1.0 - screenFraction),
                    heightDimension: .fractionalHeight(1.0)
                )
            }
            let screenGroup = NSCollectionLayoutGroup.horizontal(layoutSize: screenSize, subitems: [screenItem])
            let cameraGroup = cameraGridGroup(columns: columns, rows: rows, layoutSize: cameraSize)
            outerGroup = NSCollectionLayoutGroup.horizontal(layoutSize: outerSize, subitems: [screenGroup, cameraGroup])
        } else {
            let columns: Int
            switch visibleCameraCount {
            case 1:
                columns = 1
            case 2:
                columns = 2
            case 3:
                columns = 3
            case 4:
                columns = 4
            default:
                columns = 4
            }
            let rows = Int(ceil(Double(visibleCameraCount) / Double(columns)))
            let screenFraction: CGFloat
            switch visibleCameraCount {
            case 1:
                screenFraction = 0.88
            case 2...4:
                screenFraction = 0.84
            default:
                screenFraction = rows > 2 ? 0.76 : 0.80
            }
            let cameraFraction = 1.0 - screenFraction
            let screenSize: NSCollectionLayoutSize
            let cameraSize: NSCollectionLayoutSize
            if let g = groupAbsoluteExtent {
                screenSize = NSCollectionLayoutSize(
                    widthDimension: .absolute(max(1, g.width)),
                    heightDimension: .absolute(max(1, g.height * screenFraction))
                )
                cameraSize = NSCollectionLayoutSize(
                    widthDimension: .absolute(max(1, g.width)),
                    heightDimension: .absolute(max(1, g.height * cameraFraction))
                )
            } else {
                screenSize = NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1.0),
                    heightDimension: .fractionalHeight(screenFraction)
                )
                cameraSize = NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1.0),
                    heightDimension: .fractionalHeight(cameraFraction)
                )
            }
            let screenGroup = NSCollectionLayoutGroup.horizontal(layoutSize: screenSize, subitems: [screenItem])
            let cameraGroup = cameraGridGroup(columns: columns, rows: rows, layoutSize: cameraSize)
            outerGroup = NSCollectionLayoutGroup.vertical(layoutSize: outerSize, subitems: [screenGroup, cameraGroup])
        }

        let section = NSCollectionLayoutSection(group: outerGroup)
        return section
    }
}
#endif
