import FloatBoardCore
import AppKit
import Combine
import SwiftUI

@MainActor
final class UIState: ObservableObject {
    enum Mode { case banner, expanded, minimized, hidden }
    enum Tab: Hashable, CaseIterable {
        case board, bar, groups, connectors
        var title: String {
            switch self {
            case .board: "Board"
            case .bar: "Bar"
            case .groups: "Groups"
            case .connectors: "Connectors"
            }
        }
    }

    @Published var mode: Mode = .banner
    @Published var tab: Tab = .board
    @Published var hovering = false
    /// Set when the board should open with the "new task" box focused.
    @Published var wantsAddFocus = false
    /// Quick add happens inside the one-line banner, without opening the board.
    @Published var quickAdding = false
    /// How the one-line bar orders tasks and what it shows (Bar tab).
    @Published var bar = BarConfig() { didSet { bar.save(store: logStore) } }
    private var logStore: Store?
    /// Loads the saved bar settings once the store exists (so a problem can be logged).
    func loadBar(store: Store) { logStore = store; bar = BarConfig.load(store: store) }
    /// Board search (highlights matching tasks).
    @Published var search = ""
    /// The match Enter / ⇧Enter has moved to (scrolled into view, outlined more strongly).
    @Published var currentMatch: Int64?
    /// True once you've pressed Enter (or opened a found task): clearing the search then stays put
    /// instead of scrolling back to where you were before searching.
    @Published var searchCommitted = false
    /// Text typed in quick add; kept if the box closes because you clicked elsewhere.
    @Published var quickDraft = ""
    /// Pinned: the full board stays open when you click into another app.
    @Published var pinned = UserDefaults.standard.bool(forKey: "boardPinned") {
        didSet { UserDefaults.standard.set(pinned, forKey: "boardPinned") }
    }

    func openAdd() {
        if mode == .expanded {
            tab = .board
            wantsAddFocus = true
        } else {
            mode = .banner
            quickAdding = true
        }
    }
}

/// A panel that floats above normal windows, on every Space, without stealing focus
/// until you click into it.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that reports hover over the whole panel even when the app isn't active,
/// and lets the first click on a button work immediately.
final class HoverHostingView<Content: View>: NSHostingView<Content> {
    var onHover: ((Bool) -> Void)?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) {
        if event.trackingArea === area { onHover?(true) } else { super.mouseEntered(with: event) }
    }

    override func mouseExited(with event: NSEvent) {
        if event.trackingArea === area { onHover?(false) } else { super.mouseExited(with: event) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A grip you can drag to move the floating panel.
/// The ≡ button: click opens FloatBoard's menu.
struct DragHandle: NSViewRepresentable {
    /// Supplies the menu to show (set by the app delegate).
    @MainActor static var makeMenu: (() -> NSMenu)?

    final class Grip: NSView {
        override func mouseDown(with event: NSEvent) {
            let menu: NSMenu? = MainActor.assumeIsolated { DragHandle.makeMenu?() }
            guard let menu, let window else { return }
            let h = menu.size.height
            let onScreen = window.convertToScreen(convert(bounds, to: nil))
            let roomBelow = onScreen.minY - (window.screen?.visibleFrame.minY ?? 0)
            // popUp(at:) places the menu's top-left corner at the point (this view isn't flipped).
            let y = roomBelow > h + 8 ? -4 : bounds.maxY + 4 + h
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: self)
        }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    }
    func makeNSView(context: Context) -> Grip { Grip() }
    func updateNSView(_ nsView: Grip, context: Context) {}
}

/// Two windows:
/// - the **bar**: a borderless panel fixed full-width at the bottom (banner, or a small pill);
/// - the **board**: a standard macOS window (traffic lights, tiling, full screen, ⌘W/⌘M) opened from the bar.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let panel: FloatingPanel
    let board: NSWindow
    private let ui: UIState
    private var bag = Set<AnyCancellable>()
    private var applying = false

    static let bannerHeight: CGFloat = 30
    /// Smallest the board can be resized to without anything getting squeezed.
    static let boardMinSize = NSSize(width: 800, height: 520)
    static let pillSize = CGSize(width: 70, height: 24)
    static let defaultBottomGap: CGFloat = 2
    /// One level above the Dock, so the bar can sit over it.
    static let aboveDock = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)

    private var screen: NSScreen { NSScreen.main ?? NSScreen.screens[0] }

    /// Bar: full width, at the very bottom of the screen.
    private var barFrame: NSRect {
        let f = screen.frame
        return NSRect(x: f.minX, y: f.minY + Self.defaultBottomGap, width: f.width, height: Self.bannerHeight)
    }

    /// Board's default spot: 1200×600, centred, just above the bar.
    private var defaultBoardFrame: NSRect {
        let vf = screen.visibleFrame
        let w = min(1200, vf.width - 24), bottom = barFrame.maxY + 6
        let h = min(600, vf.maxY - bottom - 6)
        return NSRect(x: vf.midX - w / 2, y: bottom, width: w, height: h)
    }

    init(store: Store, ui: UIState, google: Google) {
        self.ui = ui
        ui.loadBar(store: store)

        // --- Bar
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: Self.bannerHeight),
                              styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                              backing: .buffered, defer: false)
        // On every normal desktop, but not over full-screen apps (they get the whole screen).
        panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.level = Self.aboveDock // after isFloatingPanel, which resets the level
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        let host = HoverHostingView(rootView: AnyView(
            RootView().environmentObject(store).environmentObject(ui).environmentObject(google)))
        host.onHover = { [weak ui] h in ui?.hovering = h }
        host.sizingOptions = []
        panel.contentView = host

        // --- Board: a normal titled window with a transparent title bar our header sits in.
        board = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 600),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        board.title = "FloatBoard"
        board.titleVisibility = .hidden // the tabs take the title's place
        // Standard unified toolbar (title, tabs, search, Guide, pin) supplied by the SwiftUI view.
        board.toolbarStyle = .unifiedCompact // slimmer toolbar controls
        board.isReleasedWhenClosed = false
        board.contentMinSize = Self.boardMinSize
        board.minSize = Self.boardMinSize
        board.collectionBehavior = [.fullScreenPrimary, .managed]
        board.tabbingMode = .disallowed
        board.initialFirstResponder = nil
        let boardHost = NSHostingView(rootView: AnyView(
            ExpandedView()
                .background(Color(nsColor: .windowBackgroundColor))
                .environmentObject(store).environmentObject(ui).environmentObject(google)))
        boardHost.sizingOptions = []
        boardHost.sceneBridgingOptions = [.toolbars] // SwiftUI .toolbar / .searchable → window toolbar
        board.contentView = boardHost
        super.init()
        board.delegate = self
        // Standard frame memory: restores the last size/position (or uses the default the first time).
        board.setFrame(defaultBoardFrame, display: false)
        board.setFrameAutosaveName("FloatBoardBoard")
        enforceMinimum()

        ui.$mode.removeDuplicates().sink { [weak self] m in
            DispatchQueue.main.async { self?.apply(m) }
        }.store(in: &bag)

        // 📌 pinned: board floats above other windows (and doesn't collapse on outside clicks).
        ui.$pinned.removeDuplicates().sink { [weak self] p in
            self?.board.level = p ? .floating : .normal
        }.store(in: &bag)

        // Quick add needs keyboard focus; a non-activating panel can take it without
        // pulling the app you're working in to the background.
        ui.$quickAdding.removeDuplicates().sink { [weak self] on in
            guard let self else { return }
            DispatchQueue.main.async {
                if on { self.panel.makeKeyAndOrderFront(nil) }
                else if self.panel.isKeyWindow { self.panel.resignKey() }
            }
        }.store(in: &bag)

        // The bar hides while the board covers its strip (fill, full screen, tiling, dragged there).
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                     NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            NotificationCenter.default.publisher(for: name, object: board)
                .sink { [weak self] _ in self?.updateBarVisibility() }
                .store(in: &bag)
        }

        NotificationCenter.default.publisher(for: .floatBoardResetBoard)
            .sink { [weak self] _ in self?.doubleClickTitleArea() }
            .store(in: &bag)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                // Only re-lay-out: this also fires when the Dock grows to hold a minimised window, and
                // re-applying the mode there would un-minimise the board straight away.
                self?.relayout()
            }.store(in: &bag)
    }

    /// The strip other windows stay clear of: the bar, while it's showing as a bar.
    var reservedFrame: NSRect? {
        guard ui.mode == .banner || ui.mode == .expanded, panel.isVisible else { return nil }
        return barFrame
    }

    /// ≡ menu: board back to its default size and spot above the bar.
    func resetBoard() {
        if board.styleMask.contains(.fullScreen) { board.toggleFullScreen(nil) }
        board.setFrame(defaultBoardFrame, display: true, animate: true)
    }

    /// Double-click on empty board space: whatever the Mac is set to do for title-bar double-clicks
    /// (System Settings → Desktop & Dock): zoom/fill (default) or minimise.
    func doubleClickTitleArea() {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize" {
        case "Minimize": board.miniaturize(nil)
        case "None": break
        default: board.zoom(nil)
        }
    }

    // MARK: Board window delegate

    /// Zoom (green button option-click, double-click): fill the screen down to just above the bar.
    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        guard window === board else { return newFrame }
        var f = (window.screen ?? screen).visibleFrame
        let barTop = barFrame.maxY + 4
        if f.minY < barTop { f.size.height -= barTop - f.minY; f.origin.y = barTop }
        return f
    }

    /// Live resizing can't go below the minimum.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard sender === board else { return frameSize }
        return NSSize(width: max(frameSize.width, Self.boardMinSize.width),
                      height: max(frameSize.height, Self.boardMinSize.height))
    }

    /// Anything else that shrinks it (restored frame, tiling): grow back, keeping the top-left corner.
    func windowDidResize(_ notification: Notification) {
        guard (notification.object as? NSWindow) === board else { return }
        enforceMinimum()
    }

    private func enforceMinimum() {
        guard !board.styleMask.contains(.fullScreen) else { return }
        var f = board.frame
        let m = Self.boardMinSize
        guard f.width < m.width - 0.5 || f.height < m.height - 0.5 else { return }
        let top = f.maxY
        f.size = NSSize(width: max(f.width, m.width), height: max(f.height, m.height))
        f.origin.y = top - f.height
        board.setFrame(f, display: true)
    }

    /// Red button / ⌘W: close the board back to the bar (the window is kept for next time).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === board { ui.mode = .banner; return false }
        return true
    }

    /// Screen or Dock changed: put the bar back in place and keep the board on screen, without showing or hiding anything.
    func relayout() {
        switch ui.mode {
        case .hidden: break
        case .minimized:
            let s = Self.pillSize, b = barFrame
            setBar(NSRect(x: b.maxX - s.width - 6, y: b.minY, width: s.width, height: s.height))
        case .banner, .expanded: setBar(barFrame)
        }
        if board.isVisible && !board.isMiniaturized { enforceMinimum() }
        updateBarVisibility()
    }

    func apply(_ mode: UIState.Mode) {
        // Bar
        switch mode {
        case .hidden:
            panel.orderOut(nil)
        case .minimized:
            let s = Self.pillSize, b = barFrame
            setBar(NSRect(x: b.maxX - s.width - 6, y: b.minY, width: s.width, height: s.height))
        case .banner, .expanded:
            setBar(barFrame)
        }
        // Board
        if mode == .expanded {
            if board.isMiniaturized { board.deminiaturize(nil) }
            enforceMinimum()
            NSApp.activate()
            board.makeKeyAndOrderFront(nil)
            // Open with nothing focused (macOS would otherwise put the cursor in the search box);
            // ⌘N / quick add still focus the add row explicitly.
            if !ui.wantsAddFocus {
                // SwiftUI restores the last focused field shortly after the window becomes key,
                // so clear focus once now and again after that.
                NotificationCenter.default.post(name: .floatBoardClearFocus, object: nil)
                for delay in [0.0, 0.15, 0.35] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self, !self.ui.wantsAddFocus else { return }
                        self.board.makeFirstResponder(nil)
                    }
                }
            }
        } else if board.isVisible || board.isMiniaturized {
            if board.styleMask.contains(.fullScreen) { board.toggleFullScreen(nil) }
            board.orderOut(nil)
            // Closing the board ends any search and drops keyboard focus.
            ui.search = ""
            ui.currentMatch = nil
            NotificationCenter.default.post(name: .floatBoardClearFocus, object: nil)
        }
        updateBarVisibility()
    }

    private func setBar(_ f: NSRect) {
        applying = true
        panel.setFrame(f, display: true)
        applying = false
        updateBarVisibility()
    }

    /// Show the bar unless it's closed, or the open board is covering its strip.
    private func updateBarVisibility() {
        guard ui.mode != .hidden else { panel.orderOut(nil); return }
        let boardShowing = board.isVisible && !board.isMiniaturized
        let covered = boardShowing && (board.styleMask.contains(.fullScreen)
                                       || board.frame.intersects(barFrame.insetBy(dx: 0, dy: 1)))
        if covered { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }
}

/// Empty header space you can drag to move the open board; double-click resets it.
struct WindowDragArea: NSViewRepresentable {
    var onDoubleClick: () -> Void = {}

    final class DragView: NSView {
        var onDoubleClick: () -> Void = {}
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { onDoubleClick(); return }
            window?.performDrag(with: event) // standard window drag, incl. edge tiling
        }
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    func makeNSView(context: Context) -> DragView {
        let v = DragView(); v.onDoubleClick = onDoubleClick; return v
    }
    func updateNSView(_ v: DragView, context: Context) { v.onDoubleClick = onDoubleClick }
}
