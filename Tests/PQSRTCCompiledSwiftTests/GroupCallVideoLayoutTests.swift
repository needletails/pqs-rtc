import Foundation
import Testing

@testable import PQSRTC

@Suite(.serialized)
struct GroupCallVideoLayoutTests {
    private static let containers: [GroupCallLayoutSize] = [
        GroupCallLayoutSize(width: 390, height: 844),
        GroupCallLayoutSize(width: 844, height: 390),
        GroupCallLayoutSize(width: 768, height: 1024),
        GroupCallLayoutSize(width: 1024, height: 768),
    ]

    private static let platforms: [GroupCallLayoutPlatform] = [.iOS, .android, .macOS]

    @Test("conference cameras 1...16 have contained non-overlapping frames")
    func conferenceCamerasHaveContainedNonOverlappingFrames() {
        for container in Self.containers {
            for cameraCount in 1...16 {
                for platform in Self.platforms {
                    let visible = GroupCallVideoLayoutPolicy.visibleCameraCountForPage(
                        totalCameras: cameraCount,
                        platform: platform,
                        mode: .conference
                    )
                    switch platform {
                    case .iOS, .android:
                        #expect(visible == min(cameraCount, 12))
                    case .macOS:
                        #expect(visible == cameraCount)
                    }

                    let frames = GroupCallVideoLayoutPolicy.conferenceTileFrames(
                        itemCount: visible,
                        containerSize: container,
                        platform: platform
                    )
                    #expect(frames.count == visible)
                    assertValidTiles(frames, container: container)
                    assertPlatformSixteenByNine(frames, platform: platform, itemCount: visible)
                }
            }
        }
    }

    @Test("portrait conference stacks; landscape conference is a horizontal row")
    func conferenceOrientationStacksPortraitAndRowsLandscape() {
        let portraitPhone = GroupCallLayoutSize(width: 390, height: 844)
        let landscapePhone = GroupCallLayoutSize(width: 844, height: 390)
        for platform in Self.platforms {
            for cameraCount in 2...4 {
                let portraitFrames = GroupCallVideoLayoutPolicy.conferenceTileFrames(
                    itemCount: cameraCount,
                    containerSize: portraitPhone,
                    platform: platform
                )
                #expect(portraitFrames.count == cameraCount)
                let portraitXSpread = (portraitFrames.map(\.x).max() ?? 0) - (portraitFrames.map(\.x).min() ?? 0)
                let portraitYSpread = (portraitFrames.map(\.y).max() ?? 0) - (portraitFrames.map(\.y).min() ?? 0)
                #expect(portraitYSpread > 40, "portrait conference must stack vertically")
                #expect(portraitXSpread < 24, "portrait conference must be a single column, not side by side")

                let landscapeFrames = GroupCallVideoLayoutPolicy.conferenceTileFrames(
                    itemCount: cameraCount,
                    containerSize: landscapePhone,
                    platform: platform
                )
                #expect(landscapeFrames.count == cameraCount)
                let landscapeXSpread = (landscapeFrames.map(\.x).max() ?? 0) - (landscapeFrames.map(\.x).min() ?? 0)
                let landscapeYSpread = (landscapeFrames.map(\.y).max() ?? 0) - (landscapeFrames.map(\.y).min() ?? 0)
                #expect(landscapeXSpread > 40, "landscape conference must run horizontally")
                #expect(landscapeYSpread < 24, "landscape conference must be a single row")
            }
        }
    }

    @Test("conference tiles pack from the top inset")
    func conferenceTilesPackFromTheTopInset() {
        for container in Self.containers {
            for cameraCount in 2...9 {
                for platform in Self.platforms {
                    let frames = GroupCallVideoLayoutPolicy.conferenceTileFrames(
                        itemCount: cameraCount,
                        containerSize: container,
                        platform: platform
                    )
                    #expect(frames.count == cameraCount)
                    let insets = GroupCallVideoLayoutPolicy.conferenceContentInsets(for: cameraCount)
                    let top = frames.map(\.y).min() ?? .greatestFiniteMagnitude
                    #expect(
                        abs(top - insets.top) < 1,
                        "conference tiles must start at the top inset, not float in leftover height"
                    )
                    #expect(top < container.height * 0.25)
                }
            }
        }
    }

    @Test("share leftover cameras pack from the top of the leftover band")
    func shareLeftoverCamerasPackFromTheTop() {
        for container in Self.containers {
            for cameraCount in 1...4 {
                for platform in Self.platforms {
                    let layout = GroupCallVideoLayoutPolicy.screenShareDominantFrames(
                        cameraTileCount: cameraCount,
                        containerSize: container,
                        platform: platform
                    )
                    #expect(layout.cameras.count == cameraCount)
                    let insets = GroupCallVideoLayoutPolicy.conferenceContentInsets(for: cameraCount)
                    let isWide = container.width > container.height
                    let expectedTop = isWide
                        ? insets.top
                        : layout.screen.maxY + insets.top
                    let top = layout.cameras.map(\.y).min() ?? .greatestFiniteMagnitude
                    #expect(
                        abs(top - expectedTop) < 1.5,
                        "share leftover cameras must start at the top of the leftover, not the vertical center"
                    )
                }
            }
        }
    }

    @Test("Apple conference tiles sit below the top safe edge")
    func appleConferenceTilesSitBelowTheTopSafeEdge() {
        let safeTop = 59.0
        let portraitPhone = GroupCallLayoutSize(width: 390, height: 844)
        for platform in [GroupCallLayoutPlatform.iOS, .macOS] {
            let frames = GroupCallVideoLayoutPolicy.conferenceTileFrames(
                itemCount: 2,
                containerSize: portraitPhone,
                platform: platform,
                safeAreaTop: safeTop
            )
            let insets = GroupCallVideoLayoutPolicy.conferenceContentInsets(for: 2)
            let top = frames.map(\.y).min() ?? .greatestFiniteMagnitude
            #expect(abs(top - (insets.top + safeTop)) < 1)
            #expect(top >= safeTop)
        }

        let android = GroupCallVideoLayoutPolicy.conferenceTileFrames(
            itemCount: 2,
            containerSize: portraitPhone,
            platform: .android,
            safeAreaTop: safeTop
        )
        let androidInsets = GroupCallVideoLayoutPolicy.conferenceContentInsets(for: 2)
        #expect(abs((android.map(\.y).min() ?? 0) - androidInsets.top) < 1)
    }

    @Test("Apple landscape share sidebar cameras sit below the top safe edge")
    func appleLandscapeShareSidebarCamerasSitBelowTheTopSafeEdge() {
        let safeTop = 59.0
        let landscapePhone = GroupCallLayoutSize(width: 844, height: 390)
        let apple = GroupCallVideoLayoutPolicy.screenShareDominantFrames(
            cameraTileCount: 2,
            containerSize: landscapePhone,
            platform: .iOS,
            safeAreaTop: safeTop
        )
        let insets = GroupCallVideoLayoutPolicy.conferenceContentInsets(for: 2)
        let top = apple.cameras.map(\.y).min() ?? .greatestFiniteMagnitude
        #expect(abs(top - (insets.top + safeTop)) < 1.5)

        let portrait = GroupCallVideoLayoutPolicy.screenShareDominantFrames(
            cameraTileCount: 2,
            containerSize: GroupCallLayoutSize(width: 390, height: 844),
            platform: .iOS,
            safeAreaTop: safeTop
        )
        let leftoverTop = portrait.screen.maxY + insets.top
        #expect(abs((portrait.cameras.map(\.y).min() ?? 0) - leftoverTop) < 1.5)
    }

    @Test("tablet conference follows the same portrait-stack / landscape-row rule")
    func tabletConferenceFollowsOrientationRule() {
        let portraitTablet = GroupCallLayoutSize(width: 768, height: 1024)
        let landscapeTablet = GroupCallLayoutSize(width: 1024, height: 768)
        for platform in Self.platforms {
            for cameraCount in 2...4 {
                let portraitFrames = GroupCallVideoLayoutPolicy.conferenceTileFrames(
                    itemCount: cameraCount,
                    containerSize: portraitTablet,
                    platform: platform
                )
                let portraitXSpread = (portraitFrames.map(\.x).max() ?? 0) - (portraitFrames.map(\.x).min() ?? 0)
                let portraitYSpread = (portraitFrames.map(\.y).max() ?? 0) - (portraitFrames.map(\.y).min() ?? 0)
                #expect(portraitYSpread > 40, "iPad/tablet portrait must stack")
                #expect(portraitXSpread < 24, "iPad/tablet portrait must be one column")

                let landscapeFrames = GroupCallVideoLayoutPolicy.conferenceTileFrames(
                    itemCount: cameraCount,
                    containerSize: landscapeTablet,
                    platform: platform
                )
                let landscapeXSpread = (landscapeFrames.map(\.x).max() ?? 0) - (landscapeFrames.map(\.x).min() ?? 0)
                let landscapeYSpread = (landscapeFrames.map(\.y).max() ?? 0) - (landscapeFrames.map(\.y).min() ?? 0)
                #expect(landscapeXSpread > 40, "iPad/tablet landscape must run horizontally")
                #expect(landscapeYSpread < 24, "iPad/tablet landscape must be one row")
            }
        }
    }

    @Test("tablet portrait share leftover keeps cameras on a horizontal strip")
    func tabletPortraitShareKeepsHorizontalCameraStrip() {
        let portraitTablet = GroupCallLayoutSize(width: 768, height: 1024)
        let landscapeTablet = GroupCallLayoutSize(width: 1024, height: 768)
        for platform in Self.platforms {
            let portraitShare = GroupCallVideoLayoutPolicy.screenShareDominantFrames(
                cameraTileCount: 3,
                containerSize: portraitTablet,
                platform: platform
            )
            #expect(abs(portraitShare.screen.width - portraitTablet.width) < 0.5)
            #expect(portraitShare.cameras.count == 3)
            let portraitYSpread = (portraitShare.cameras.map(\.y).max() ?? 0) - (portraitShare.cameras.map(\.y).min() ?? 0)
            #expect(portraitYSpread < 8, "tablet portrait leftover must stay a horizontal camera strip")

            let landscapeShare = GroupCallVideoLayoutPolicy.screenShareDominantFrames(
                cameraTileCount: 3,
                containerSize: landscapeTablet,
                platform: platform
            )
            #expect(landscapeShare.cameras.count == 3)
            let landscapeXSpread = (landscapeShare.cameras.map(\.x).max() ?? 0) - (landscapeShare.cameras.map(\.x).min() ?? 0)
            #expect(landscapeXSpread < 24, "tablet landscape share must keep cameras in a sidebar column")
        }
    }

    @Test("unknown or landscape remote content stays 16:9; portrait remotes become 9:16")
    func remoteCameraItemFollowsIncomingUprightSize() {
        #expect(
            abs(
                GroupCallVideoLayoutPolicy.cameraTileAspectForRemoteContent(
                    uprightWidth: 0,
                    uprightHeight: 0
                ) - GroupCallVideoLayoutPolicy.landscapeTileAspect
            ) < 0.0001
        )
        #expect(
            abs(
                GroupCallVideoLayoutPolicy.cameraTileAspectForRemoteContent(
                    uprightWidth: 1920,
                    uprightHeight: 1080
                ) - GroupCallVideoLayoutPolicy.landscapeTileAspect
            ) < 0.0001
        )
        #expect(
            abs(
                GroupCallVideoLayoutPolicy.cameraTileAspectForRemoteContent(
                    uprightWidth: 1080,
                    uprightHeight: 1920
                ) - GroupCallVideoLayoutPolicy.portraitTileAspect
            ) < 0.0001
        )
    }

    @Test("share tile stays full-bleed while only the remote item follows content orientation")
    func shareTileStaysFullBleedWhileRemoteItemFollowsContent() {
        let portraitPhone = GroupCallLayoutSize(width: 390, height: 844)
        let landscapeRemote = GroupCallVideoLayoutPolicy.screenShareDominantFrames(
            cameraTileCount: 1,
            containerSize: portraitPhone,
            platform: .iOS,
            cameraTileAspect: GroupCallVideoLayoutPolicy.landscapeTileAspect
        )
        let portraitRemote = GroupCallVideoLayoutPolicy.screenShareDominantFrames(
            cameraTileCount: 1,
            containerSize: portraitPhone,
            platform: .iOS,
            cameraTileAspect: GroupCallVideoLayoutPolicy.portraitTileAspect
        )
        #expect(landscapeRemote.cameras.count == 1)
        #expect(portraitRemote.cameras.count == 1)
        #expect(abs(landscapeRemote.screen.width - portraitPhone.width) < 0.5)
        #expect(abs(portraitRemote.screen.width - portraitPhone.width) < 0.5)
        #expect(abs(landscapeRemote.screen.height - portraitRemote.screen.height) < 0.5)
        #expect(abs(landscapeRemote.screen.width - portraitRemote.screen.width) < 0.5)

        let landscapeCamera = landscapeRemote.cameras[0]
        let portraitCamera = portraitRemote.cameras[0]
        #expect(landscapeCamera.width > landscapeCamera.height)
        #expect(
            abs(landscapeCamera.width / max(1, landscapeCamera.height) - GroupCallVideoLayoutPolicy.landscapeTileAspect) < 0.08
        )
        #expect(
            landscapeCamera.width > portraitPhone.width * 0.75,
            "landscape remote content must span the strip, not a 9:16 portrait box"
        )
        #expect(portraitCamera.height > portraitCamera.width)
        #expect(
            abs(portraitCamera.width / max(1, portraitCamera.height) - GroupCallVideoLayoutPolicy.portraitTileAspect) < 0.08
        )
        #expect(landscapeCamera.width > portraitCamera.width * 1.5)
    }

    @Test("default share-strip cameras are landscape even on a portrait collection")
    func defaultShareStripCamerasAreLandscapeOnPortraitCollection() {
        let portrait = GroupCallLayoutSize(width: 390, height: 844)
        let landscape = GroupCallLayoutSize(width: 844, height: 390)
        #expect(
            abs(
                GroupCallVideoLayoutPolicy.screenShareCameraTileAspect(collectionSize: portrait)
                    - GroupCallVideoLayoutPolicy.landscapeTileAspect
            ) < 0.0001
        )

        for platform in Self.platforms {
            let portraitLayout = GroupCallVideoLayoutPolicy.screenShareDominantFrames(
                cameraTileCount: 1,
                containerSize: portrait,
                platform: platform
            )
            #expect(portraitLayout.cameras.count == 1)
            let camera = portraitLayout.cameras[0]
            #expect(camera.width > camera.height)
            #expect(
                abs(camera.width / max(1, camera.height) - GroupCallVideoLayoutPolicy.landscapeTileAspect) < 0.08
            )

            let landscapeLayout = GroupCallVideoLayoutPolicy.screenShareDominantFrames(
                cameraTileCount: 1,
                containerSize: landscape,
                platform: platform
            )
            let landscapeCamera = landscapeLayout.cameras[0]
            #expect(landscapeCamera.width > landscapeCamera.height)
            #expect(
                landscapeCamera.maxX >= landscape.width - 24,
                "landscape device sidebar camera should run end to end of the camera column"
            )
        }
    }

    @Test("mixed remote aspects keep landscape end-to-end and portrait as 9:16")
    func mixedRemoteAspectsKeepDistinctItemShapes() {
        let portraitPhone = GroupCallLayoutSize(width: 390, height: 844)
        let layout = GroupCallVideoLayoutPolicy.screenShareDominantFrames(
            cameraTileCount: 2,
            containerSize: portraitPhone,
            platform: .iOS,
            cameraTileAspects: [
                GroupCallVideoLayoutPolicy.landscapeTileAspect,
                GroupCallVideoLayoutPolicy.portraitTileAspect
            ]
        )
        #expect(layout.cameras.count == 2)
        #expect(abs(layout.screen.width - portraitPhone.width) < 0.5)
        #expect(layout.cameras[0].width > layout.cameras[0].height)
        #expect(layout.cameras[1].height > layout.cameras[1].width)
        #expect(layout.cameras[0].width > layout.cameras[1].width)
    }

    @Test("portrait tile aspect wins over a wide leftover host box")
    func portraitTileAspectWinsOverWideHostBox() {
        let stripHost = GroupCallLayoutSize(width: 390, height: 220)
        let layout = GroupCallVideoLayoutPolicy.screenShareDominantFrames(
            cameraTileCount: 1,
            containerSize: stripHost,
            platform: .iOS,
            cameraTileAspect: GroupCallVideoLayoutPolicy.portraitTileAspect
        )
        #expect(layout.cameras.count == 1)
        let camera = layout.cameras[0]
        #expect(camera.height > camera.width)
        #expect(
            abs(camera.width / max(1, camera.height) - GroupCallVideoLayoutPolicy.portraitTileAspect) < 0.08
        )
    }

    @Test("screen-share cameras 0...16 keep one screen and a non-overlapping strip")
    func screenShareCamerasKeepOneScreenAndNonOverlappingStrip() {
        for container in Self.containers {
            for cameraCount in 0...16 {
                for platform in Self.platforms {
                    let visible = GroupCallVideoLayoutPolicy.visibleCameraCountForPage(
                        totalCameras: cameraCount,
                        platform: platform,
                        mode: .screenShare
                    )
                    switch platform {
                    case .android:
                        #expect(visible == min(cameraCount, 8))
                    case .iOS, .macOS:
                        #expect(visible == cameraCount)
                    }

                    let layout = GroupCallVideoLayoutPolicy.screenShareDominantFrames(
                        cameraTileCount: cameraCount,
                        containerSize: container,
                        platform: platform
                    )
                    #expect(layout.cameras.count == visible)
                    #expect(layout.allFrames.count == 1 + visible)
                    assertValidTiles(layout.allFrames, container: container)
                    #expect(layout.screen.width > 0 && layout.screen.height > 0)
                    for camera in layout.cameras {
                        #expect(!layout.screen.overlaps(camera))
                        #expect(!layout.screen.contains(camera))
                    }

                    if GroupCallVideoLayoutPolicy.usesHorizontalPhoneCameraStrip(
                        cameraTileCount: visible,
                        containerSize: container
                    ), visible > 1 {
                        let ys = layout.cameras.map(\.y)
                        let spread = (ys.max() ?? 0) - (ys.min() ?? 0)
                        #expect(spread < 8, "phone 1...4 cameras must stay on a horizontal strip")
                    }

                    let isWide = container.width > max(1, container.height) * 1.08
                    if isWide, visible > 1 {
                        let xs = layout.cameras.map(\.x)
                        let spread = (xs.max() ?? 0) - (xs.min() ?? 0)
                        #expect(spread < max(24, container.width * 0.08), "wide layouts must use a vertical sidebar")
                    }
                }
            }
        }
    }

    @Test("stop conference frames differ from active-share strip frames")
    func stopConferenceFramesDifferFromActiveShareStrip() {
        for container in Self.containers {
            for cameraCount in 1...16 {
                for platform in Self.platforms {
                    let conferenceVisible = GroupCallVideoLayoutPolicy.visibleCameraCountForPage(
                        totalCameras: cameraCount,
                        platform: platform,
                        mode: .conference
                    )
                    let shareVisible = GroupCallVideoLayoutPolicy.visibleCameraCountForPage(
                        totalCameras: cameraCount,
                        platform: platform,
                        mode: .screenShare
                    )
                    let stopFrames = GroupCallVideoLayoutPolicy.conferenceTileFrames(
                        itemCount: conferenceVisible,
                        containerSize: container,
                        platform: platform
                    )
                    let shareLayout = GroupCallVideoLayoutPolicy.screenShareDominantFrames(
                        cameraTileCount: cameraCount,
                        containerSize: container,
                        platform: platform
                    )
                    let comparableCount = min(stopFrames.count, shareLayout.cameras.count, shareVisible)
                    guard comparableCount > 0 else { continue }
                    let stopComparable = Array(stopFrames.prefix(comparableCount))
                    let shareComparable = Array(shareLayout.cameras.prefix(comparableCount))
                    #expect(
                        stopComparable != shareComparable,
                        "cameras must leave strip size after screen-share stop"
                    )
                }
            }
        }
    }

    @Test("explicit preview host size is not flipped to match a stale orientation flag")
    func explicitPreviewHostSizeIsNotFlipped() {
        let splitColumn = GroupCallLayoutSize(width: 336, height: 1024)
        let resolved = GroupCallVideoLayoutPolicy.resolvedLocalPreviewHostSize(
            explicitContainer: splitColumn,
            fallbackContainer: GroupCallLayoutSize(width: 1024, height: 768),
            requestedIsLandscape: true
        )
        #expect(resolved == splitColumn)

        let flipped = GroupCallVideoLayoutPolicy.resolvedLocalPreviewHostSize(
            explicitContainer: nil,
            fallbackContainer: GroupCallLayoutSize(width: 390, height: 844),
            requestedIsLandscape: true
        )
        #expect(flipped.width == 844)
        #expect(flipped.height == 390)
    }

    @Test("compact iPad column keeps a contained local preview")
    func compactIPadColumnKeepsContainedLocalPreview() {
        let splitColumn = GroupCallLayoutSize(width: 336, height: 1024)
        let preview = GroupCallVideoLayoutPolicy.localPreviewOverlaySize(
            platform: .iOS,
            containerSize: splitColumn,
            isTablet: true
        )
        #expect(preview.width > 0 && preview.height > 0)
        #expect(preview.width <= splitColumn.width * 0.48 + 0.01)
        #expect(preview.height <= splitColumn.height * 0.40 + 0.01)
        #expect(
            GroupCallLayoutRect(
                x: 0,
                y: 0,
                width: preview.width,
                height: preview.height
            ).isContained(in: splitColumn)
        )
    }

    @Test("local preview is a contained overlay excluded from screen-share snapshots")
    func localPreviewIsContainedOverlayExcludedFromSnapshots() {
        for container in Self.containers {
            for platform in Self.platforms {
                let isTablet = container.minSide >= 450
                let preview = GroupCallVideoLayoutPolicy.localPreviewOverlayFrame(
                    platform: platform,
                    containerSize: container,
                    isTablet: isTablet
                )
                #expect(preview.width > 0 && preview.height > 0)
                #expect(preview.isContained(in: container))
                let share = GroupCallVideoLayoutPolicy.screenShareDominantFrames(
                    cameraTileCount: 2,
                    containerSize: container,
                    platform: platform
                )
                #expect(preview.width * preview.height < share.screen.width * share.screen.height * 0.45)

                if platform == .android {
                    let expected = GroupCallVideoLayoutPolicy.localPreviewOverlaySize(
                        platform: .android,
                        containerSize: container,
                        isTablet: isTablet
                    )
                    let maxWidth: Double = isTablet ? 240 : 180
                    let fraction: Double = isTablet ? 0.28 : 0.34
                    #expect(expected.width <= maxWidth + 0.01)
                    #expect(expected.width <= container.minSide * fraction + 0.01)
                }
            }
        }

        let models = [
            ScreenShareLayoutSnapshotItem(id: "preview", isPreview: true, isScreenShare: false),
            ScreenShareLayoutSnapshotItem(id: "screen", isPreview: false, isScreenShare: true),
            ScreenShareLayoutSnapshotItem(id: "camera", isPreview: false, isScreenShare: false),
        ]
        let snapshot = GroupCallVideoLayoutPolicy.snapshotModelsForScreenShareLayout(
            models: models,
            previewDetached: true
        )
        #expect(snapshot.contains(where: \.isPreview) == false)
        #expect(snapshot.first?.isScreenShare == true)
    }

    @Test("transition-time cell bounds win for expansion and shrink")
    func transitionBoundsPreferCurrentCellOverStaleViewBounds() {
        let staleStrip = GroupCallLayoutRect(x: 0, y: 700, width: 180, height: 100)
        let expandedCell = GroupCallLayoutRect(x: 20, y: 20, width: 350, height: 600)
        let attributes = GroupCallLayoutRect(x: 20, y: 20, width: 350, height: 600)
        let expanded = GroupCallVideoLayoutPolicy.effectiveMountedVideoBounds(
            viewBounds: staleStrip,
            cellContentBounds: expandedCell,
            layoutAttributesBounds: attributes,
            transitionPending: true
        )
        #expect(expanded == expandedCell)

        let staleExpanded = GroupCallLayoutRect(x: 0, y: 0, width: 390, height: 700)
        let stripCell = GroupCallLayoutRect(x: 10, y: 720, width: 90, height: 50)
        let shrunk = GroupCallVideoLayoutPolicy.effectiveMountedVideoBounds(
            viewBounds: staleExpanded,
            cellContentBounds: stripCell,
            layoutAttributesBounds: stripCell,
            transitionPending: true
        )
        #expect(shrunk == stripCell)
    }

    @Test("settled screen-share strip prefers the current cell over a stale portrait view")
    func settledStripPrefersCurrentCellOverStalePortraitView() {
        let stalePortrait = GroupCallLayoutRect(x: 0, y: 0, width: 390, height: 700)
        let stripCell = GroupCallLayoutRect(x: 15, y: 600, width: 320, height: 180)
        let settled = GroupCallVideoLayoutPolicy.effectiveMountedVideoBounds(
            viewBounds: stalePortrait,
            cellContentBounds: stripCell,
            layoutAttributesBounds: stripCell,
            transitionPending: false
        )
        #expect(settled == stripCell)
    }

    @Test("Android page switch and roster churn create a new expected set")
    func androidPageSwitchAndRosterChurnReplaceExpectedSet() {
        var state = ScreenShareLayoutTransitionPolicy.beginTransition(
            state: .idle,
            isStartingShare: true,
            expectedIdentities: ["p1", "p2"]
        )
        let firstGeneration = state.generation
        #expect(state.phase == .awaitingStartLayout(generation: firstGeneration))

        state = ScreenShareLayoutTransitionPolicy.replacingExpectedIdentities(
            state: state,
            newIdentities: ["p3", "p4"]
        )
        #expect(state.generation == firstGeneration &+ 1)
        #expect(state.expectedIdentities == ["p3", "p4"])
        #expect(
            ScreenShareLayoutTransitionPolicy.shouldAcceptSurfaceReport(
                capturedGeneration: firstGeneration,
                identity: "p1",
                state: state
            ) == false
        )

        let afterRoster = ScreenShareLayoutTransitionPolicy.replacingExpectedIdentities(
            state: state,
            newIdentities: ["p3", "p4", "p5"]
        )
        #expect(afterRoster.generation == state.generation &+ 1)
        #expect(afterRoster.expectedIdentities == ["p3", "p4", "p5"])
        #expect(afterRoster.reportedIdentities.isEmpty)
    }

    private func assertValidTiles(_ frames: [GroupCallLayoutRect], container: GroupCallLayoutSize) {
        for frame in frames {
            #expect(frame.width > 0)
            #expect(frame.height > 0)
            #expect(frame.isContained(in: container))
        }
        for index in frames.indices {
            for other in frames.indices where other > index {
                #expect(!frames[index].overlaps(frames[other]))
            }
        }
    }

    private func assertPlatformSixteenByNine(
        _ frames: [GroupCallLayoutRect],
        platform: GroupCallLayoutPlatform,
        itemCount: Int
    ) {
        if platform == .android, itemCount == 1 {
            return
        }
        for frame in frames {
            let aspect = frame.width / max(1, frame.height)
            #expect(abs(aspect - GroupCallVideoLayoutPolicy.targetAspect) < 0.08)
        }
    }
}
