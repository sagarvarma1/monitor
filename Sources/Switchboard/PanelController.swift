import AppKit
import Combine
import SwiftUI
import SwitchboardCore

/// Which corner of the glass stays put. The glass grows away from it, toward the middle of the screen.
enum Corner: Equatable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    var isTop: Bool { self == .topLeading || self == .topTrailing }
    var isTrailing: Bool { self == .topTrailing || self == .bottomTrailing }

    var alignment: Alignment {
        switch self {
        case .topLeading: return .topLeading
        case .topTrailing: return .topTrailing
        case .bottomLeading: return .bottomLeading
        case .bottomTrailing: return .bottomTrailing
        }
    }

    var unitPoint: UnitPoint {
        switch self {
        case .topLeading: return .topLeading
        case .topTrailing: return .topTrailing
        case .bottomLeading: return .bottomLeading
        case .bottomTrailing: return .bottomTrailing
        }
    }

    /// The corner nearest the screen edges for a point: grow right from the left half, down from the top half.
    static func nearest(to p: CGPoint, in screen: NSRect) -> Corner {
        let top = p.y > screen.midY, trailing = p.x > screen.midX
        switch (top, trailing) {
        case (true, true): return .topTrailing
        case (true, false): return .topLeading
        case (false, true): return .bottomTrailing
        case (false, false): return .bottomLeading
        }
    }
}

/// What the glass shows. Hover or pin expands; a session that newly needs you peeks for a few seconds.
final class UIState: ObservableObject {
    enum Mode: Equatable {
        case compact, peek(String), done([String]), expanded

        var key: String {
            switch self {
            case .compact: return "compact"
            case .peek: return "peek"
            case .done: return "done"
            case .expanded: return "expanded"
            }
        }
    }

    @Published private(set) var hovering = false
    @Published var pinned = false { didSet { if pinned { unseenDone.removeAll() } } }
    @Published private(set) var peekID: String?
    /// Sessions that just finished, shown briefly as a "done" flash on the pill.
    @Published private(set) var doneIDs: [String] = []
    /// Finished sessions you haven't looked at yet; their dots keep a ring until you hover or open the list.
    @Published var unseenDone: Set<String> = []
    @Published var expandedID: String?
    @Published var corner = Corner.topTrailing
    /// The session whose reply field is open. While set, the panel stays open and takes keyboard focus.
    @Published var replyingID: String? {
        didSet {
            if let replyingID { pinned = true; expandedID = replyingID }
        }
    }
    /// While dragging, the glass shrinks to the pill so it's easy to place.
    @Published var dragging = false
    /// After a drop the pointer is still over the pill; don't expand until it leaves and comes back.
    @Published private(set) var hoverSuppressed = false
    /// Room the glass has to grow into from its corner, so a long list scrolls instead of running off screen.
    @Published var maxHeight: CGFloat = 600

    private var hoverWork: DispatchWorkItem?
    private var peekWork: DispatchWorkItem?
    private var doneWork: DispatchWorkItem?
    private var doneShownAt: Date?

    /// A peek beats hover: reaching for its buttons mustn't morph it into the list under the pointer.
    var mode: Mode {
        if dragging { return .compact }
        if pinned { return .expanded }
        if let peekID { return .peek(peekID) }
        if !doneIDs.isEmpty { return .done(doneIDs) }
        if hovering && !hoverSuppressed { return .expanded }
        return .compact
    }

    /// Delays on both edges so sweeping the pointer past the pill doesn't flicker it open or shut.
    /// Over a peek, its timer pauses; it closes shortly after the pointer leaves.
    func setHover(_ inside: Bool) {
        hoverWork?.cancel()
        if !inside { hoverSuppressed = false }
        if peekID != nil {
            if inside { peekWork?.cancel() } else { schedulePeekEnd(after: 1.5) }
        }
        if !doneIDs.isEmpty {
            if inside { doneWork?.cancel() } else { scheduleDoneEnd(after: 1.2) }
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hovering != inside else { return }
            self.hovering = inside
            if inside && self.mode == .expanded { self.unseenDone.removeAll() }  // you're looking at the list now
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (inside ? 0.15 : 0.4), execute: work)
    }

    func endDrag() {
        dragging = false
        hoverSuppressed = true
    }

    func peek(_ id: String, for seconds: TimeInterval) {
        guard !hovering, !pinned else { return }
        peekID = id
        schedulePeekEnd(after: seconds)
    }

    private func schedulePeekEnd(after seconds: TimeInterval) {
        peekWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.peekID = nil }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func endPeek() {
        peekWork?.cancel()
        peekID = nil
    }

    /// Flashes "done" on the pill. Sessions finishing close together merge into one flash, which stretches a
    /// little for each newcomer but never past a few seconds, so a burst can't keep the pill busy.
    func flashDone(_ id: String) {
        unseenDone.insert(id)
        guard !pinned, !(hovering && !hoverSuppressed) else { return }  // the list is already showing it
        if doneIDs.isEmpty { doneShownAt = Date() }
        doneIDs.removeAll { $0 == id }
        doneIDs.append(id)
        let shownFor = Date().timeIntervalSince(doneShownAt ?? Date())
        scheduleDoneEnd(after: max(1.5, min(3.5, 6 - shownFor)))
    }

    func endDone() {
        doneWork?.cancel()
        doneIDs = []
        doneShownAt = nil
    }

    private func scheduleDoneEnd(after seconds: TimeInterval) {
        doneWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.endDone() }
        doneWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Drops flashes and rings for sessions that are no longer waiting for review (you replied, or they ended).
    func pruneDone(keeping reviewIDs: Set<String>) {
        if !unseenDone.isSubset(of: reviewIDs) { unseenDone.formIntersection(reviewIDs) }
        if doneIDs.contains(where: { !reviewIDs.contains($0) }) {
            doneIDs.removeAll { !reviewIDs.contains($0) }
            if doneIDs.isEmpty { endDone() }
        }
    }
}

/// Floating panel that joins every Space and only takes keyboard focus while a reply is being typed. Being a
/// non-activating panel, even then it doesn't activate the app, so your terminal stays the frontmost app.
final class FloatingPanel: NSPanel {
    var acceptsKeyboard = false
    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { false }
}

/// Lets the first click on the (never-key) panel hit buttons and rows directly.
final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The window is a fixed transparent canvas big enough for the expanded list, so the glass can morph inside it
/// without the window resizing mid-animation. It only takes the mouse while the pointer is over the glass;
/// everywhere else clicks fall through to whatever is underneath.
///
/// Position is a single point, the glass's anchored corner in screen coordinates, plus which corner that is.
final class PanelController {
    /// Gap kept between the glass and the screen edges.
    static let edgeInset: CGFloat = 8
    private static let anchorKey = "pillAnchor"

    let panel: FloatingPanel
    private let ui: UIState
    private var hosting: ClickThroughHostingView<PanelRoot>!
    /// The glass's resting size, reported by PanelRoot.
    private var glassSize = CGSize.zero
    private var anchor: CGPoint?
    private var pointerInside = false
    private var dragOffset: CGPoint?
    private var monitors: [Any] = []
    private var replyObserver: AnyCancellable?

    init(store: SessionStore, ui: UIState, setup: Setup,
         onFocus: @escaping (String) -> Void, onDecide: @escaping (String, PermissionDecision) -> Void,
         onReply: @escaping (String, String) -> Void) {
        self.ui = ui
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 56),
                              styleMask: [.nonactivatingPanel, .borderless],
                              backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false  // the glass draws its own
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true

        if let saved = UserDefaults.standard.array(forKey: Self.anchorKey) as? [Double], saved.count == 2 {
            anchor = CGPoint(x: saved[0], y: saved[1])
        }

        hosting = ClickThroughHostingView(rootView: PanelRoot(
            store: store, ui: ui, setup: setup, onFocus: onFocus, onDecide: onDecide, onReply: onReply,
            onSize: { [weak self] in self?.glassDidResize($0) }))
        hosting.sizingOptions = []  // the window keeps its own frame
        panel.contentView = hosting

        // Global monitors see events headed to other apps (no permission needed for mouse events);
        // the local one covers events headed to us while the pointer is over the glass.
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: moves) { [weak self] _ in self?.trackPointer() } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: moves) { [weak self] event in
            self?.trackPointer()
            return event
        } as Any)
        // Dragging is handled here rather than with a SwiftUI gesture: the view under the pointer morphs (hover
        // expands, drag collapses), which can cancel a gesture mid-press. Events still reach SwiftUI unless a
        // drag is under way, so clicks and buttons behave normally.
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.handleDrag(event) ?? event
        } as Any)
        // Clicking anywhere else unpins (and drops a half-typed reply), like dismissing a popover.
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak ui] _ in
            ui?.replyingID = nil
            if ui?.pinned == true { ui?.pinned = false }
        } as Any)
        replyObserver = ui.$replyingID.removeDuplicates().sink { [weak self] id in
            guard let self else { return }
            self.panel.acceptsKeyboard = id != nil
            if id != nil {
                self.panel.makeKeyAndOrderFront(nil)
            } else if self.panel.isKeyWindow {
                self.panel.resignKey()
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.settle() }
        settle()
    }

    deinit { monitors.forEach(NSEvent.removeMonitor) }

    var isVisible: Bool { panel.isVisible }

    func show() {
        settle()
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
        setPointerInside(false)
    }

    func toggle() { isVisible ? hide() : show() }

    private func glassDidResize(_ size: CGSize) {
        glassSize = size
        trackPointer()
    }

    // MARK: Geometry

    private func screen(containing p: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.screens.first
    }

    /// Default spot: the top-right corner of the screen with the menu bar.
    private var defaultAnchor: CGPoint {
        let visible = NSScreen.screens.first?.visibleFrame ?? .zero
        return CGPoint(x: visible.maxX - Self.edgeInset, y: visible.maxY - Self.edgeInset)
    }

    /// The glass in screen coordinates, grown from the anchored corner.
    private var glassFrame: NSRect {
        let a = anchor ?? defaultAnchor
        let corner = ui.corner
        return NSRect(x: corner.isTrailing ? a.x - glassSize.width : a.x,
                      y: corner.isTop ? a.y - glassSize.height : a.y,
                      width: glassSize.width, height: glassSize.height)
    }

    /// Keeps the anchor on screen, picks the corner for where it sits, and lays out the canvas around it.
    private func settle() {
        var a = anchor ?? defaultAnchor
        guard let visible = screen(containing: a)?.visibleFrame.insetBy(dx: Self.edgeInset, dy: Self.edgeInset) else { return }
        a.x = min(max(a.x, visible.minX), visible.maxX)
        a.y = min(max(a.y, visible.minY), visible.maxY)
        anchor = a
        ui.corner = Corner.nearest(to: a, in: visible)
        layoutCanvas()
    }

    private func layoutCanvas() {
        let a = anchor ?? defaultAnchor
        guard let visible = screen(containing: a)?.visibleFrame else { return }
        let corner = ui.corner
        let m = PanelRoot.margin
        let room = corner.isTop ? a.y - visible.minY : visible.maxY - a.y
        let height = max(120, min(room - Self.edgeInset, visible.height * 0.85))
        if ui.maxHeight != height { ui.maxHeight = height }
        let width = PanelRoot.maxWidth + 2 * m
        let canvasHeight = height + 2 * m
        let x = corner.isTrailing ? a.x + m - width : a.x - m
        let y = corner.isTop ? a.y + m - canvasHeight : a.y - m
        panel.setFrame(NSRect(x: x, y: y, width: width, height: canvasHeight), display: true)
    }

    // MARK: Dragging

    private var pressLocation: CGPoint?

    private func handleDrag(_ event: NSEvent) -> NSEvent? {
        guard event.window === panel else { return event }
        let mouse = NSEvent.mouseLocation
        switch event.type {
        case .leftMouseDown:
            pressLocation = mouse
            return event
        case .leftMouseDragged:
            guard let press = pressLocation else { return event }
            if dragOffset == nil && hypot(mouse.x - press.x, mouse.y - press.y) < 4 { return event }
            drag()
            return nil
        case .leftMouseUp:
            pressLocation = nil
            guard dragOffset != nil else { return event }
            endDrag()
            return nil  // so the press doesn't also count as a click (e.g. pinning the pill) where it was dropped
        default:
            return event
        }
    }

    /// The pill follows the pointer, keeping the grab offset (clamped, so grabbing the big list lands on the pill).
    private func drag() {
        let mouse = NSEvent.mouseLocation
        if dragOffset == nil {
            ui.dragging = true
            ui.pinned = false
            let f = glassFrame
            dragOffset = CGPoint(x: max(-60, min(60, mouse.x - f.midX)), y: max(-12, min(12, mouse.y - f.midY)))
        }
        guard let offset = dragOffset, let visible = screen(containing: mouse)?.visibleFrame else { return }
        let center = CGPoint(x: mouse.x - offset.x, y: mouse.y - offset.y)
        let corner = Corner.nearest(to: center, in: visible)
        anchor = CGPoint(x: corner.isTrailing ? center.x + glassSize.width / 2 : center.x - glassSize.width / 2,
                         y: corner.isTop ? center.y + glassSize.height / 2 : center.y - glassSize.height / 2)
        if corner != ui.corner { ui.corner = corner }
        layoutCanvas()
    }

    private func endDrag() {
        guard dragOffset != nil else { return }
        dragOffset = nil
        settle()
        if let a = anchor { UserDefaults.standard.set([Double(a.x), Double(a.y)], forKey: Self.anchorKey) }
        ui.endDrag()
        trackPointer()
    }

    // MARK: Pointer

    private func trackPointer() {
        guard dragOffset == nil else { return }  // mid-drag the pointer is on the pill by definition
        setPointerInside(panel.isVisible && glassFrame.contains(NSEvent.mouseLocation))
    }

    private func setPointerInside(_ inside: Bool) {
        guard inside != pointerInside else { return }
        pointerInside = inside
        panel.ignoresMouseEvents = !inside
        ui.setHover(inside)
    }
}
