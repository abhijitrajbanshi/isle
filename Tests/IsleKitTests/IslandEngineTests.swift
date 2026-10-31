import CoreGraphics
import Testing
@testable import IsleKit

/// Sleep that returns at once, so timed behaviour runs on the next yields.
private let instant: IslandEngine.Sleep = { _ in await Task.yield() }

/// Short gaps pass instantly; display durations and holds never elapse.
private let longWaitsBlock: IslandEngine.Sleep = { duration in
    if duration < .seconds(1) { await Task.yield() } else { try await Task.sleep(for: .seconds(60)) }
}

/// Lets queued main-actor tasks run.
@MainActor
private func settle() async {
    for _ in 0..<20 { await Task.yield() }
}

@MainActor
struct PresentationTests {
    @Test func idleWithNothingGoingOn() {
        let engine = IslandEngine()
        #expect(engine.presentation == .idle)
    }

    @Test func highestPriorityActivityTakesTheNotch() {
        let engine = IslandEngine()
        engine.activities = { [.nowPlaying, .privacy, .timer] }
        #expect(engine.presentation == .compact(primary: .timer, secondary: .nowPlaying))
    }

    @Test func singleActivityHasNoBubble() {
        let engine = IslandEngine()
        engine.activities = { [.calendar] }
        #expect(engine.presentation == .compact(primary: .calendar, secondary: nil))
    }

    @Test func alertsOverrideActivitiesAndExpansionOverridesAlerts() {
        let engine = IslandEngine(sleep: instant)
        engine.activities = { [.nowPlaying] }
        engine.present(.capsLock(isOn: true))
        #expect(engine.presentation == .alert(.capsLock(isOn: true)))
        engine.expand()
        #expect(engine.presentation == .expanded)
        #expect(engine.alert == nil)
    }
}

@MainActor
struct AlertTests {
    @Test func sameKindUpdatesInPlace() {
        let engine = IslandEngine()
        engine.present(.volume(level: 0.2, muted: false))
        engine.present(.volume(level: 0.3, muted: false))
        #expect(engine.alert == .volume(level: 0.3, muted: false))
    }

    @Test func bannersQueueAndShowInTurn() async {
        // short gaps pass instantly; display durations never elapse
        let engine = IslandEngine(sleep: { duration in
            if duration < .seconds(1) { await Task.yield() } else { try await Task.sleep(for: .seconds(60)) }
        })
        let airpods = DeviceInfo(name: "AirPods", symbol: "airpods", battery: 80, isConnected: true)
        engine.present(.device(airpods))
        engine.present(.lowBattery(level: 10))
        #expect(engine.alert == .device(airpods))
        engine.dismissAlert()
        await settle()
        #expect(engine.alert == .lowBattery(level: 10))
    }

    @Test func hudDuringQueueGapKeepsQueuedBanner() async {
        let engine = IslandEngine(sleep: { duration in
            if duration < .seconds(1) { await Task.yield() } else { try await Task.sleep(for: .seconds(60)) }
        })
        engine.present(.lowBattery(level: 10))
        engine.present(.timerDone)
        engine.dismissAlert()
        engine.present(.capsLock(isOn: true))   // arrives in the gap between banners
        await settle()
        #expect(engine.alert == .capsLock(isOn: true))   // the HUD isn't interrupted…
        engine.dismissAlert()
        await settle()
        #expect(engine.alert == .timerDone)              // …and the banner still shows
    }

    @Test func hudsPreemptBanners() {
        let engine = IslandEngine()
        engine.present(.lowBattery(level: 10))
        engine.present(.volume(level: 0.5, muted: false))
        #expect(engine.alert == .volume(level: 0.5, muted: false))
    }

    @Test func alertsDismissThemselves() async {
        let engine = IslandEngine(sleep: instant)
        engine.present(.capsLock(isOn: false))
        await settle()
        #expect(engine.alert == nil)
    }

    @Test func hoveringKeepsAlertUp() async {
        let engine = IslandEngine(sleep: longWaitsBlock)
        engine.present(.capsLock(isOn: true))
        engine.pointerMoved(inside: true)
        await settle()
        #expect(engine.alert == .capsLock(isOn: true))
    }

    /// Regression: an alert that appeared under a resting pointer never went away.
    @Test func restingPointerDoesNotHoldAlert() async {
        let engine = IslandEngine(sleep: instant)
        engine.present(.capsLock(isOn: true))
        engine.pointerMoved(inside: true, byMotion: false)
        await settle()
        #expect(engine.alert == nil)
    }

    @Test func hoverHoldIsCapped() async {
        let engine = IslandEngine(sleep: instant)
        engine.present(.capsLock(isOn: true))
        engine.pointerMoved(inside: true)
        await settle()
        #expect(engine.alert == nil)
    }

    /// Regression: a HUD used to replace a showing banner, losing it for good.
    @Test func hudInterruptsBannerThenBannerReturns() async {
        let engine = IslandEngine(sleep: longWaitsBlock)
        engine.present(.lowBattery(level: 10))
        engine.present(.volume(level: 0.4, muted: false))
        #expect(engine.alert == .volume(level: 0.4, muted: false))
        engine.dismissAlert()
        await settle()
        #expect(engine.alert == .lowBattery(level: 10))
    }

    /// Regression: banners arriving while expanded were dropped and never re-sent.
    @Test func bannerWhileExpandedShowsAfterCollapse() async {
        let engine = IslandEngine(sleep: longWaitsBlock)
        engine.expand()
        engine.present(.lowBattery(level: 10))
        engine.present(.volume(level: 0.4, muted: false))   // momentary: dropped
        #expect(engine.presentation == .expanded)
        engine.collapse()
        await settle()
        #expect(engine.alert == .lowBattery(level: 10))
    }

    @Test func expandedIgnoresAlertsExceptTimer() {
        let engine = IslandEngine()
        engine.expand()
        engine.present(.capsLock(isOn: true))
        #expect(engine.presentation == .expanded)
        engine.present(.timerDone)
        #expect(engine.presentation == .alert(.timerDone))
    }
}

@MainActor
struct PointerTests {
    @Test func hoverExpandsAfterDelay() async {
        let engine = IslandEngine(sleep: instant)
        engine.pointerMoved(inside: true)
        #expect(!engine.isExpanded)
        await settle()
        #expect(engine.isExpanded)
    }

    @Test func islandGrowingUnderRestingPointerDoesNotExpand() async {
        let engine = IslandEngine(sleep: instant)
        engine.activities = { [.nowPlaying] }
        engine.pointerMoved(inside: true, byMotion: false)
        await settle()
        #expect(!engine.isExpanded)
        engine.pointerMoved(inside: true, byMotion: true)   // then the user moves
        await settle()
        #expect(engine.isExpanded)
    }

    @Test func passingThroughDoesNotExpand() async {
        let engine = IslandEngine(sleep: instant)
        engine.pointerMoved(inside: true)
        engine.pointerMoved(inside: false)
        await settle()
        #expect(!engine.isExpanded)
    }

    @Test func hoverDisabledRequiresClick() async {
        let engine = IslandEngine(sleep: instant)
        engine.expandsOnHover = false
        engine.pointerMoved(inside: true)
        await settle()
        #expect(!engine.isExpanded)
        engine.activate()
        #expect(engine.isExpanded)
    }

    @Test func leavingCollapses() async {
        let engine = IslandEngine(sleep: instant)
        engine.expand()
        engine.pointerMoved(inside: true)
        engine.pointerMoved(inside: false)
        await settle()
        #expect(!engine.isExpanded)
    }

    @Test func fileDragKeepsShelfOpenOutside() async {
        let engine = IslandEngine(sleep: instant)
        engine.fileDragEnteredDropZone()
        #expect(engine.isExpanded && engine.tab == .shelf)
        engine.pointerMoved(inside: true)
        engine.pointerMoved(inside: false)
        await settle()
        #expect(engine.isExpanded)
        engine.fileDragEnded()
        await settle()
        #expect(!engine.isExpanded)
    }

    @Test func clickOutsideCollapses() {
        let engine = IslandEngine()
        engine.expand()
        engine.clickedOutside()
        #expect(!engine.isExpanded)
    }
}

struct LayoutTests {
    let layout = IslandLayout(metrics: .preview)
    let notch = NotchMetrics.preview.size

    @Test func idleFitsInsideTheHardwareNotch() {
        let shape = layout.shape(for: .idle, isHovering: false)
        #expect(shape.outerWidth <= notch.width)
        #expect(shape.height <= notch.height)
    }

    @Test(arguments: LiveActivity.allCases)
    func compactLeavesTheNotchClear(activity: LiveActivity) {
        let shape = layout.shape(for: .compact(primary: activity, secondary: nil), isHovering: false)
        #expect(shape.width - 2 * layout.sideWidth(for: activity) >= notch.width)
    }

    @Test func frameIsCentredOnTheNotch() {
        let frame = layout.frame(for: .expanded, isHovering: false)
        #expect(abs(frame.midX - NotchMetrics.preview.screenFrame.midX) < 0.5)
        #expect(frame.maxY == NotchMetrics.preview.screenFrame.maxY)
    }

    @Test func hitRectIncludesBubble() {
        let p = Presentation.compact(primary: .timer, secondary: .nowPlaying)
        let shape = layout.shape(for: p, isHovering: false)
        let bubbleCentre = CGPoint(x: NotchMetrics.preview.screenFrame.midX + shape.outerWidth / 2
                                      + IslandLayout.bubbleGap + layout.bubbleDiameter / 2,
                                   y: NotchMetrics.preview.screenFrame.maxY - layout.bubbleDiameter / 2)
        #expect(layout.hitRect(for: p, isHovering: false).contains(bubbleCentre))
    }
}

struct SwipeTests {
    @Test func firesOncePerSwipe() {
        var swipe = SwipeInterpreter(threshold: 40)
        #expect(swipe.feed(dx: 0, dy: -20) == nil)
        #expect(swipe.feed(dx: 0, dy: -25) == .up)
        #expect(swipe.feed(dx: 0, dy: -60) == nil)
        swipe.reset()
        #expect(swipe.feed(dx: 50, dy: 3) == .right)
    }

    @Test func ignoresDiagonals() {
        var swipe = SwipeInterpreter(threshold: 40)
        #expect(swipe.feed(dx: 35, dy: 30) == nil)
    }
}
