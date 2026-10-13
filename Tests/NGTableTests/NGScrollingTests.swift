#if os(macOS)
import AppKit
import Testing
@testable import NGTable

// The table's own scrolling paths that system scroll views would cover:
// the overlay scroller's knob and track, and the rubber band past the edges.

@MainActor
private final class Numbers: NGTableViewDataSource {
    func numberOfRows(in tableView: NGTableView) -> Int { 500 }
    func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue { .number(Double(row)) }
}

@Suite("Scrolling")
@MainActor
struct NGScrollingTests {
    /// A window holding a 16×200 vertical scroller whose knob is a quarter of its track.
    private func makeScroller() -> (NGOverlayScroller, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 16, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let scroller = NGOverlayScroller(orientation: .vertical)
        scroller.frame = NSRect(x: 0, y: 0, width: 16, height: 200)
        window.contentView = NSView(frame: scroller.frame)
        window.contentView?.addSubview(scroller)
        scroller.knobProportion = 0.25
        return (scroller, window)
    }

    private func mouse(_ type: NSEvent.EventType, y: CGFloat, in scroller: NGOverlayScroller) throws -> NSEvent {
        let point = scroller.convert(NSPoint(x: 8, y: y), to: nil)   // `y` from the top: the scroller is flipped.
        return try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                               windowNumber: scroller.window?.windowNumber ?? 0, context: nil,
                                               eventNumber: 0, clickCount: 1, pressure: 1))
    }

    /// Dragging the knob scrolls in proportion to the track it travels, and
    /// stops at the ends; releasing ends the tracking.
    @Test func draggingTheKnob() throws {
        let (scroller, window) = makeScroller()
        defer { withExtendedLifetime(window) {} }
        var values: [CGFloat] = []
        scroller.onScroll = { values.append($0) }
        // The knob: 2 points inset, 49 long (a quarter of 196); 147 points of travel.
        scroller.mouseDown(with: try mouse(.leftMouseDown, y: 20, in: scroller))
        #expect(scroller.isTracking)
        scroller.mouseDragged(with: try mouse(.leftMouseDragged, y: 20 + 73.5, in: scroller))
        #expect(abs(scroller.value - 0.5) < 0.001)
        scroller.mouseDragged(with: try mouse(.leftMouseDragged, y: 400, in: scroller))
        #expect(scroller.value == 1)
        scroller.mouseUp(with: try mouse(.leftMouseUp, y: 400, in: scroller))
        #expect(!scroller.isTracking)
        #expect(values.count == 2 && values.last == 1)
    }

    /// A click in the track pages toward it (or jumps there, with the
    /// system's "jump to the spot that's clicked" setting).
    @Test func clickingTheTrack() throws {
        let (scroller, window) = makeScroller()
        defer { withExtendedLifetime(window) {} }
        var pages: [Int] = []
        var values: [CGFloat] = []
        scroller.onPage = { pages.append($0) }
        scroller.onScroll = { values.append($0) }
        scroller.mouseDown(with: try mouse(.leftMouseDown, y: 150, in: scroller))
        scroller.mouseUp(with: try mouse(.leftMouseUp, y: 150, in: scroller))
        if UserDefaults.standard.bool(forKey: "AppleScrollerPagingBehavior") {
            #expect(pages.isEmpty && values.count == 1)
        } else {
            #expect(pages == [1] && values.isEmpty)
        }
        #expect(!scroller.isTracking)
    }

    private func scrollEvent(phase: Int64 = 0) throws -> NSEvent {
        let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0))
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        return try #require(NSEvent(cgEvent: event))
    }

    /// Pulling past the top meets resistance, pulling back scrolls again, and
    /// letting go past the edge springs back and ignores the momentum.
    @Test func rubberBandAtTheTop() async throws {
        let numbers = Numbers()
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        table.columns = [.column(NGTableColumn("n", title: "N", width: 200))]
        table.dataSource = numbers
        let window = NSWindow(contentRect: table.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = table
        table.layoutSubtreeIfNeeded()
        defer { withExtendedLifetime((window, numbers)) {} }
        let event = try scrollEvent()

        table.scrollVerticallyWithElasticity(by: 40, event: event)
        #expect(table.contentOffset.y == 0)
        let first = -table.verticalOverscroll
        #expect(first > 0 && first < 40)
        table.scrollVerticallyWithElasticity(by: 40, event: event)
        let second = -table.verticalOverscroll - first
        #expect(second > 0 && second < first)   // Ever more resistance.
        // Pulling back past the edge: the rest scrolls the content.
        table.scrollVerticallyWithElasticity(by: -100, event: event)
        #expect(table.verticalOverscroll == 0)
        #expect(table.contentOffset.y == 20)

        // Pulled past the edge again, then let go: back to the edge.
        table.scrollVerticallyWithElasticity(by: 60, event: event)
        #expect(table.verticalOverscroll < 0)
        let ended = try scrollEvent(phase: 4)
        guard ended.phase.contains(.ended) else { return }   // Events from CGEvent without phases on this system.
        table.handleElasticPhases(of: ended)
        #expect(table.ignoresMomentum)
        let deadline = ContinuousClock.now + .seconds(2)
        while table.verticalOverscroll != 0, ContinuousClock.now < deadline {
            try await _Concurrency.Task.sleep(for: .milliseconds(20))
            table.stepElasticAnimation(try #require(table.elasticLink))   // Display links don't run off screen.
        }
        #expect(table.verticalOverscroll == 0)
        #expect(table.elasticLink == nil)
    }

    /// Every change of the scroll position is posted, after the rows are laid
    /// out there (what a clip view's bounds change is to NSTableView apps,
    /// e.g. loading the next page); asking for the same position isn't.
    @Test func scrollingIsPosted() throws {
        let numbers = Numbers()
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        table.columns = [.column(NGTableColumn("n", title: "N", width: 200))]
        table.dataSource = numbers
        table.layoutSubtreeIfNeeded()
        defer { withExtendedLifetime(numbers) {} }
        var offsets: [CGPoint] = []
        var lastShown: Int?
        // Posted on the main thread; the closure isn't main-actor isolated.
        nonisolated(unsafe) let observed = table
        let observer = NotificationCenter.default.addObserver(forName: NGTableView.didScrollNotification, object: table, queue: nil) { _ in
            MainActor.assumeIsolated {
                offsets.append(observed.contentOffset)
                lastShown = observed.rowIndexes(in: observed.bounds).last
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        table.scroll(to: CGPoint(x: 0, y: 2_000))
        table.scroll(to: CGPoint(x: 0, y: 2_000))
        #expect(offsets == [CGPoint(x: 0, y: 2_000)])
        #expect((lastShown ?? 0) > Int(2_000 / table.rowHeight))
        table.scrollRowToVisible(499)
        #expect(offsets.count == 2 && offsets.last == table.contentOffset)
        // New columns scroll back to the start.
        table.columns = [.column(NGTableColumn("m", title: "M", width: 200))]
        #expect(offsets.count == 3 && offsets.last == .zero)
    }

    /// A scroll view that records the scroll events that reach it.
    private final class Container: NSScrollView {
        var received: [CGPoint] = []
        override func scrollWheel(with event: NSEvent) {
            received.append(CGPoint(x: event.scrollingDeltaX, y: event.scrollingDeltaY))
        }
    }

    private func wheelEvent(dx: Int32 = 0, dy: Int32 = 0, phase: Int64 = 0, momentum: Int64 = 0) throws -> NSEvent {
        let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0))
        if phase != 0 || momentum != 0 {
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        }
        return try #require(NSEvent(cgEvent: event))
    }

    /// Scrolling on an axis the table has nothing to scroll on goes to the
    /// view that contains it, like a nested NSScrollView's: a short table in
    /// a long form scrolls the form. Whole gestures go, momentum included.
    @Test func scrollsItCantTakeGoToItsContainer() throws {
        final class Few: NGTableViewDataSource {
            func numberOfRows(in tableView: NGTableView) -> Int { 3 }
            func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue { .number(Double(row)) }
        }
        let few = Few()
        // A form in a scroll view, the table in the form.
        let container = Container(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let form = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 1_000))
        container.documentView = form
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        // Wider than the table: it scrolls sideways only.
        table.columns = [.column(NGTableColumn("n", title: "N", width: 300)), .column(NGTableColumn("m", title: "M", width: 300))]
        table.dataSource = few
        form.addSubview(table)
        table.layoutSubtreeIfNeeded()
        defer { withExtendedLifetime(few) {} }
        #expect(table.layoutMetrics.maxOffset.y == 0 && table.layoutMetrics.maxOffset.x > 0)

        // A mouse wheel: up and down go on, sideways the table takes.
        table.scrollWheel(with: try wheelEvent(dy: -30))
        #expect(container.received.count == 1 && table.contentOffset == .zero)
        table.scrollWheel(with: try wheelEvent(dx: -30))
        #expect(container.received.count == 1 && table.contentOffset.x == 30)

        // A trackpad gesture up and down, then its momentum: all go on, from
        // its beginning; the table neither scrolls nor bounces.
        let began = try wheelEvent(phase: 1)
        guard began.phase.contains(.began) else { return }   // Events from CGEvent without phases on this system.
        container.received = []
        table.scrollWheel(with: began)
        table.scrollWheel(with: try wheelEvent(dy: -20, phase: 2))
        table.scrollWheel(with: try wheelEvent(dy: -20, phase: 2))
        table.scrollWheel(with: try wheelEvent(phase: 4))
        table.scrollWheel(with: try wheelEvent(dy: -10, momentum: 1))
        table.scrollWheel(with: try wheelEvent(momentum: 3))
        #expect(container.received.count == 6)
        #expect(table.verticalOverscroll == 0 && table.contentOffset.y == 0)
        // A gesture sideways is the table's again.
        container.received = []
        table.scrollWheel(with: try wheelEvent(phase: 1))
        table.scrollWheel(with: try wheelEvent(dx: -20, phase: 2))
        table.scrollWheel(with: try wheelEvent(phase: 4))
        #expect(container.received.isEmpty && table.contentOffset.x == 50)
        // Alone in a window, the rows still bounce up and down.
        table.removeFromSuperview()
        table.scrollWheel(with: try wheelEvent(phase: 1))
        table.scrollWheel(with: try wheelEvent(dy: 20, phase: 2))
        #expect(table.verticalOverscroll < 0)
        #expect(container.received.isEmpty)
    }

    /// Live scrolls are posted like NSScrollView's: they start with a
    /// gesture, every step is posted, and they end with the momentum, or
    /// with the gesture when no momentum follows; dragging the overlay
    /// scroller is one too.
    @Test func liveScrollsArePosted() async throws {
        let numbers = Numbers()
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        table.columns = [.column(NGTableColumn("n", title: "N", width: 200))]
        table.dataSource = numbers
        let window = NSWindow(contentRect: table.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = table
        table.layoutSubtreeIfNeeded()
        defer { withExtendedLifetime((window, numbers)) {} }
        var posted: [String] = []
        let names: [(Notification.Name, String)] = [(NGTableView.willStartLiveScrollNotification, "start"),
                                                     (NGTableView.didLiveScrollNotification, "live"),
                                                     (NGTableView.didEndLiveScrollNotification, "end")]
        let observers = names.map { name, label in
            NotificationCenter.default.addObserver(forName: name, object: table, queue: nil) { _ in
                MainActor.assumeIsolated { posted.append(label) }
            }
        }
        defer { observers.forEach(NotificationCenter.default.removeObserver) }
        let began = try wheelEvent(phase: 1)
        guard began.phase.contains(.began) else { return }   // Events from CGEvent without phases on this system.
        table.scrollWheel(with: began)
        table.scrollWheel(with: try wheelEvent(dy: -20, phase: 2))
        table.scrollWheel(with: try wheelEvent(dy: -20, phase: 2))
        table.scrollWheel(with: try wheelEvent(phase: 4))
        table.scrollWheel(with: try wheelEvent(dy: -10, momentum: 1))
        table.scrollWheel(with: try wheelEvent(dy: -10, momentum: 2))
        try await Task.sleep(for: .milliseconds(100))   // Momentum keeps it going.
        #expect(posted == ["start", "live", "live", "live", "live"])
        table.scrollWheel(with: try wheelEvent(momentum: 3))
        #expect(posted.last == "end" && posted.filter { $0 == "end" }.count == 1)
        // No momentum: it ends shortly after the fingers lift.
        posted = []
        table.scrollWheel(with: try wheelEvent(phase: 1))
        table.scrollWheel(with: try wheelEvent(dy: -20, phase: 2))
        table.scrollWheel(with: try wheelEvent(phase: 4))
        #expect(posted == ["start", "live"])
        // (Under a busy suite the main thread may come back to it late.)
        try await eventually(within: .seconds(60)) { posted.last == "end" }
        #expect(posted == ["start", "live", "end"])
        // The overlay scroller, pressed and let go.
        posted = []
        let scroller = table.verticalOverlayScroller
        let point = scroller.convert(NSPoint(x: scroller.bounds.midX, y: scroller.bounds.maxY - 4), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                        clickCount: 1, pressure: 1))
            type == .leftMouseDown ? scroller.mouseDown(with: event) : scroller.mouseUp(with: event)
        }
        #expect(posted.first == "start" && posted.last == "end")
    }
}
#endif
