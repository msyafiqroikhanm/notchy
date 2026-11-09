import AppKit
import Combine
import SwiftUI

/// Page order and stable raw identifiers (raw values are persisted only in memory, never renamed).
enum ShellTab: String, CaseIterable {
    case musik = "Musik", fokus = "Fokus", air = "Air", shelf = "Shelf", clipboard = "Clipboard"
    case tugas = "Tugas", sholat = "Sholat", widgets = "Widgets"
}

/// One typed event presentation. A later notice replaces the earlier one.
struct ShellNotice: Equatable, Identifiable {
    enum Kind: Equatable {
        case charging, disconnected, headphones, prayer, focus, water, task, shelf

        var symbol: String {
            switch self {
            case .charging: return "bolt.fill"
            case .disconnected: return "bolt.slash.fill"
            case .headphones: return "headphones"
            case .prayer: return "moon.stars.fill"
            case .focus: return "timer"
            case .water: return "drop.fill"
            case .task: return "checklist"
            case .shelf: return "tray.and.arrow.down.fill"
            }
        }
    }

    let id = UUID()
    var kind: Kind
    var title: String
    var subtitle: String
    var trailingText: String? = nil
    /// Real battery fraction for the power notices; nil hides the ring.
    var progress: Double? = nil
    var destination: ShellTab? = nil
    var duration: TimeInterval
}

final class ShellState: ObservableObject {
    @Published var expanded = false
    @Published var lyricsExpanded = false
    @Published var selectedTab = ShellTab.musik.rawValue
    @Published var notice: ShellNotice?
    var activateNotice: () -> Void = {}
    @Published var cameraWidth: CGFloat = 0
    /// Expanded header row height: the camera safe area on a notched screen, 30 pt otherwise.
    @Published var clearance: CGFloat = 30
    /// Seconds since last user input; sampled only when crossing the 60 s / 300 s stages.
    @Published var idleSeconds: Double = 0
    /// True for the 0.9 s wake response after an idle stage ends.
    @Published var waking = false
    @Published var ringProgress: Double = 0
    @Published var ringLabel = "Baterai belum tersedia"
    @Published var playing = false
    /// Popover ownership is separate so task/slider updates cannot release its interaction hold.
    @Published private var controlInteracting = false
    @Published var prayerInfoPresented = false
    var interacting: Bool {
        get { controlInteracting || prayerInfoPresented }
        set { controlInteracting = newValue }
    }
    /// True while a file drag is over the shell; the drop target view should highlight.
    @Published var dragHover = false
    /// Set by the mounted TaskView while its composer or edit form is open.
    @Published var taskEditorExpanded = false
    /// Destination presentation and layouts. Published by NotchPanel only when the target changes,
    /// never per animation frame, so mounted features do not re-layout during motion.
    @Published var profile = ShellProfile(presentation: .closed)
    @Published var layout = ShellGeometry(width: 188, height: 30, shoulder: 6, bottom: 12)
    @Published var expandedLayout = ShellGeometry(width: 520, height: 194, shoulder: 18, bottom: 28)
    /// Wired by NotchPanel / AppDelegate / TaskView so views can act without holding their owners.
    var requestDismiss: () -> Void = {}
    var requestSettings: () -> Void = {}
    var cancelTaskEditor: () -> Void = {}

    var tabIndex: Int { ShellTab.allCases.firstIndex { $0.rawValue == selectedTab } ?? 0 }
    func canStep(_ delta: Int) -> Bool { ShellTab.allCases.indices.contains(tabIndex + delta) }
    func step(_ delta: Int) {
        guard canStep(delta) else { return }
        selectedTab = ShellTab.allCases[tabIndex + delta].rawValue
    }
}

/// Main-thread frame clock that runs only while a visible transition is active.
final class ShellAnimator: NSAnimation {
    var onFrame: () -> Void = {}

    init() {
        super.init(duration: 10, animationCurve: .linear)
        animationBlockingMode = .nonblocking
        frameRate = 60
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // Keep ticking while menus or drags track the run loop.
    override var runLoopModesForAnimating: [RunLoop.Mode]? { [.common] }

    override var currentProgress: NSAnimation.Progress {
        get { super.currentProgress }
        set { super.currentProgress = newValue; onFrame() }
    }
}

/// Borderless panel whose frame is the silhouette's bounding box (body + shoulders), anchored top-center.
final class NotchPanel: NSPanel {
    var onFiles: ([URL]) -> Void = { _ in }
    var onInvalidDrop: () -> Void = {}
    var onEscape: () -> Void = {}

    private let shell: ShellState
    private let preferences: Preferences
    private let container = ShellContainer()
    private let hosting: NSHostingView<NotchView>
    private let animator = ShellAnimator()

    private var metrics: ShellScreen?
    private var motion = ShellMotion(at: ShellGeometry(width: 188, height: 30, shoulder: 6, bottom: 12))
    private var lastTick: CFTimeInterval = 0
    private var keyboardPinned = false
    private var dragging = false
    private var tabBeforeDrag: String?
    private var pressInside = false
    private var menuTracking = 0
    private var swipe = CGSize.zero
    private var hoverOpenWork: DispatchWorkItem?
    private var hoverSuppressed = false
    private var closeWork: DispatchWorkItem?
    private var noticeWork: DispatchWorkItem?
    private var idleTimer: Timer?
    private var lastIdleStage = 0
    private var cancellables = Set<AnyCancellable>()
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?

    init(shell: ShellState, preferences: Preferences, content: AnyView) {
        self.shell = shell
        self.preferences = preferences
        hosting = NSHostingView(rootView: NotchView(shell: shell, preferences: preferences, content: content))
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        collectionBehavior = [.stationary, .ignoresCycle, .fullScreenNone]
        setAccessibilityLabel("Notchy")

        hosting.sizingOptions = []
        hosting.autoresizingMask = []
        container.panel = self
        container.hosting = hosting
        container.addSubview(hosting)
        contentView = container

        shell.requestDismiss = { [weak self] in self?.dismiss() }
        shell.activateNotice = { [weak self] in
            guard let self, let notice = self.shell.notice else { return }
            if let destination = notice.destination { self.shell.selectedTab = destination.rawValue }
            self.clearNotice()
            self.openFromKeyboard()
        }
        animator.onFrame = { [weak self] in self?.tick() }

        // Only inputs that change the silhouette; battery, clock, artwork and text never restart motion.
        let inputs: [AnyPublisher<Void, Never>] = [
            shell.$expanded.map { _ in () }.eraseToAnyPublisher(),
            shell.$lyricsExpanded.map { _ in () }.eraseToAnyPublisher(),
            shell.$selectedTab.map { _ in () }.eraseToAnyPublisher(),
            shell.$notice.map { $0 != nil }.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            shell.$idleSeconds.map { _ in () }.eraseToAnyPublisher(),
            shell.$waking.map { _ in () }.eraseToAnyPublisher(),
            shell.$playing.map { _ in () }.eraseToAnyPublisher(),
            shell.$taskEditorExpanded.map { _ in () }.eraseToAnyPublisher(),
            preferences.$minimal.map { _ in () }.eraseToAnyPublisher(),
            preferences.$mascot.map { _ in () }.eraseToAnyPublisher(),
        ]
        // @Published emits before the value lands; read state on the next main turn.
        Publishers.MergeMany(inputs).receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.applyGeometry(animated: true) }
            .store(in: &cancellables)

        let nc = NotificationCenter.default
        let ws = NSWorkspace.shared.notificationCenter
        observers = [
            (nc, nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                self?.refreshScreen()
            }),
            (nc, nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: self, queue: .main) { [weak self] _ in
                guard let self, !self.occlusionState.contains(.visible) else { return }
                self.finishMotion(at: self.motion.target)
            }),
            (ws, ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.finishMotion(at: self.motion.target)
            }),
            (ws, ws.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.applyGeometry(animated: false)
            }),
            (nc, nc.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                self?.menuTracking += 1
            }),
            (nc, nc.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.menuTracking = max(0, self.menuTracking - 1)
                if !self.pointerInside { self.scheduleClose() }
            }),
        ]

        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.sampleIdle() }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer

        let mouseEvents: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseEvents) { [weak self] event in
            self?.reconcilePointer()
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) { [weak self] _ in
            self?.reconcilePointer()
        }

        refreshScreen()
        orderFrontRegardless()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // Borderless windows at the screen top would otherwise be pushed below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    // MARK: Public API

    func openFromKeyboard() {
        cancelHoverOpen()
        hoverSuppressed = false
        keyboardPinned = true
        closeWork?.cancel()
        setExpanded(true)
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in self?.selectNextKeyView(nil) }
    }

    func dismiss() {
        cancelHoverOpen()
        hoverSuppressed = pointerInside
        closeWork?.cancel()
        let wasKey = isKeyWindow
        keyboardPinned = false
        shell.interacting = false
        shell.prayerInfoPresented = false
        pressInside = false
        makeFirstResponder(nil)
        setExpanded(false)
        if wasKey { NSApp.deactivate() }
    }

    func showNotice(_ notice: ShellNotice) {
        noticeWork?.cancel()
        shell.notice = notice
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: "\(notice.title). \(notice.subtitle)",
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
        let work = DispatchWorkItem { [weak self] in self?.clearNotice() }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + notice.duration, execute: work)
    }

    func shutdown() {
        cancelHoverOpen()
        closeWork?.cancel()
        noticeWork?.cancel()
        animator.stop()
        idleTimer?.invalidate()
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        localMouseMonitor = nil
        globalMouseMonitor = nil
        observers.forEach { $0.0.removeObserver($0.1) }
        observers.removeAll()
        cancellables.removeAll()
        orderOut(nil)
        close()
    }

    private func clearNotice() {
        noticeWork?.cancel()
        noticeWork = nil
        shell.notice = nil
    }

    // MARK: Hover / drag / key handling (called by ShellContainer and window events)

    func pointerEntered() {
        closeWork?.cancel()
        guard !hoverSuppressed, !shell.expanded else { return }
        cancelHoverOpen()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hoverOpenWork = nil
            guard !self.hoverSuppressed, self.pointerInside else { return }
            self.setExpanded(true)
        }
        hoverOpenWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func pointerExited() {
        cancelHoverOpen()
        hoverSuppressed = false
        scheduleClose()
    }

    /// Valid file drag over the silhouette: remember the page, show Shelf, expand immediately.
    func fileDragEntered() {
        guard !dragging else { return }
        cancelHoverOpen()
        hoverSuppressed = false
        closeWork?.cancel()
        dragging = true
        tabBeforeDrag = shell.selectedTab
        shell.selectedTab = ShellTab.shelf.rawValue
        shell.dragHover = true
        container.setDragHighlight(true)
        setExpanded(true)
    }

    /// Exit or cancel: restore the page the user was on.
    func fileDragEnded() {
        guard dragging else { return }
        if let prior = tabBeforeDrag { shell.selectedTab = prior }
        tabBeforeDrag = nil
        dragging = false
        if shell.dragHover { shell.dragHover = false }
        container.setDragHighlight(false)
        scheduleClose()
    }

    func fileDragDropped(_ urls: [URL]) {
        tabBeforeDrag = nil
        dragging = false
        shell.dragHover = false
        container.setDragHighlight(false)
        onFiles(urls)
    }

    func invalidDragEntered() { onInvalidDrop() }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            if event.keyCode == 53, shell.expanded {
                onEscape()
                dismiss()
                return
            }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if shell.expanded, mods == [.command, .option], event.keyCode == 123 || event.keyCode == 124 {
                shell.step(event.keyCode == 123 ? -1 : 1)
                return
            }
        case .scrollWheel:
            trackSwipe(event)
        default: break
        }
        super.sendEvent(event)
        switch event.type {
        case .leftMouseDown, .rightMouseDown: pressInside = true
        case .leftMouseUp, .rightMouseUp:
            pressInside = false
            if !pointerInside { scheduleClose() }
        default: break
        }
    }

    /// One trackpad gesture moves at most one page; vertical scrolling stays with lists and lyrics.
    private func trackSwipe(_ e: NSEvent) {
        guard e.hasPreciseScrollingDeltas, e.momentumPhase.isEmpty else { return }
        if e.phase.contains(.began) { swipe = .zero }
        swipe.width += e.scrollingDeltaX
        swipe.height += e.scrollingDeltaY
        guard e.phase.contains(.ended) || e.phase.contains(.cancelled) else { return }
        let s = swipe
        swipe = .zero
        guard e.phase.contains(.ended), shell.expanded, !navigationBlocked,
              abs(s.width) > 40, abs(s.width) > 1.5 * abs(s.height) else { return }
        shell.step(s.width < 0 ? 1 : -1)
    }

    private var navigationBlocked: Bool { shell.interacting || dragging || firstResponder is NSText }

    override func resignKey() {
        super.resignKey()
        if keyboardPinned && !shell.interacting && menuTracking == 0 {
            dismiss()
        } else if shell.expanded, !pointerInside {
            scheduleClose()
        }
    }

    // MARK: Open / close

    private var pointerInside: Bool { container.containsScreenPoint(NSEvent.mouseLocation) }

    func reconcilePointer() {
        let inside = container.containsScreenPoint(NSEvent.mouseLocation)
        ignoresMouseEvents = !inside
        container.setHoverInside(inside)
    }

    private var closeBlocked: Bool {
        shell.interacting || dragging || (pressInside && NSEvent.pressedMouseButtons != 0) || menuTracking > 0 || firstResponder is NSText
    }

    private func setExpanded(_ value: Bool) {
        guard shell.expanded != value else { return }
        shell.expanded = value
        applyGeometry(animated: true)
    }

    private func cancelHoverOpen() {
        hoverOpenWork?.cancel()
        hoverOpenWork = nil
    }

    private func scheduleClose() {
        closeWork?.cancel()
        guard shell.expanded else { return }
        let work = DispatchWorkItem { [weak self] in self?.closeIfAllowed() }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func closeIfAllowed() {
        guard shell.expanded, !keyboardPinned, !pointerInside else { return }
        if closeBlocked { scheduleClose(); return }
        setExpanded(false)
    }

    // MARK: Geometry

    private func pickScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
            return CGDisplayIsBuiltin(id) != 0
        } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func refreshScreen() {
        guard let screen = pickScreen() else { return }
        let inset = screen.safeAreaInsets.top
        var camera: CGFloat = 0
        var centerX = screen.frame.midX
        if inset > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            camera = screen.frame.width - left.width - right.width
            centerX = screen.frame.minX + left.width + camera / 2
        }
        let top = camera > 0 ? inset : 0
        metrics = ShellScreen(frame: screen.frame, usableHeight: screen.frame.maxY - screen.visibleFrame.minY,
                              cameraWidth: camera, top: top, centerX: centerX, scale: screen.backingScaleFactor,
                              menuBarHeight: max(NSStatusBar.system.thickness, screen.frame.maxY - screen.visibleFrame.maxY))
        shell.cameraWidth = camera
        shell.clearance = camera > 0 ? inset : 30
        motion.floor = SIMD8(Double(camera), Double(top), 0, 0, Double(camera), 0, 0, 0)
        applyGeometry(animated: false)
    }

    private func profile(expanded: Bool) -> ShellProfile {
        let idle = shell.idleSeconds
        return ShellProfile.make(expanded: expanded, lyrics: shell.lyricsExpanded, tab: shell.selectedTab,
                                 taskEditor: shell.taskEditorExpanded, notice: shell.notice != nil,
                                 idleStage: idle >= 300 ? 2 : idle >= 60 ? 1 : 0, waking: shell.waking,
                                 playing: shell.playing, mascot: preferences.mascot, minimal: preferences.minimal)
    }

    private func applyGeometry(animated: Bool) {
        guard let metrics else { return }
        let current = profile(expanded: shell.expanded)
        let target = current.geometry(on: metrics)
        let expandedTarget = profile(expanded: true).geometry(on: metrics)
        if shell.profile != current { shell.profile = current }
        if shell.layout != target { shell.layout = target }
        if shell.expandedLayout != expandedTarget { shell.expandedLayout = expandedTarget }

        // Fixed host large enough for every layout; the silhouette clips it, so motion never resizes SwiftUI.
        let lyrics = ShellProfile(presentation: .lyrics, noticeStrip: true).geometry(on: metrics)
        let editor = ShellProfile(presentation: .taskEditor, noticeStrip: true).geometry(on: metrics)
        let transient = ShellProfile(presentation: .transient).geometry(on: metrics)
        let largest = CGSize(width: max(lyrics.totalWidth, editor.totalWidth, transient.totalWidth),
                             height: max(lyrics.height, editor.height))
        if hosting.frame.size != largest {
            hosting.setFrameSize(largest)
            container.placeHosting()
        }

        let animate = ShellMotion.shouldAnimate(requested: animated, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, visible: occlusionState.contains(.visible))
        guard animate else { finishMotion(at: target); return }
        guard target != motion.target else { return }
        let now = CACurrentMediaTime()
        motion.retarget(target, at: now)
        if !animator.isAnimating {
            lastTick = now
            animator.start()
        }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        defer { lastTick = now }
        guard now - lastTick <= ShellMotion.maxFrameGap, occlusionState.contains(.visible) else {
            finishMotion(at: motion.target)
            return
        }
        let sample = motion.settle(at: now)
        present(sample.geometry)
        if sample.settled { animator.stop() }
    }

    private func finishMotion(at target: ShellGeometry) {
        if animator.isAnimating { animator.stop() }
        motion.snap(target)
        present(target)
    }

    /// Frame, silhouette path and host placement all come from the same sample.
    private func present(_ g: ShellGeometry) {
        guard let metrics else { return }
        var safe = g
        let menuOffset = metrics.cameraWidth > 0 ? 0 : metrics.menuBarHeight
        safe.height = max(metrics.top, min(g.height, metrics.usableHeight - menuOffset - 8))
        safe.neckHeight = max(0, min(g.neckHeight, safe.height))
        let lowerHeight = safe.height - safe.neckHeight
        safe.shoulder = max(0, min(g.shoulder, lowerHeight / 2))
        safe.width = max(metrics.cameraWidth, min(g.width, metrics.frame.width - 16 - 2 * safe.shoulder))
        safe.neckWidth = max(metrics.cameraWidth, min(g.neckWidth, safe.totalWidth))
        safe.bottom = max(0, min(g.bottom, lowerHeight / 2, safe.width / 2))
        let f = ShellProfile.frame(for: safe, on: metrics)
        if f != frame { setFrame(f, display: true) }
        container.update(safe)
        reconcilePointer()
    }

    // MARK: Idle

    /// Reads system idle time (no event tap, no permission) and publishes only stage changes.
    private func sampleIdle() {
        let seconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        let stage = seconds >= 300 ? 2 : seconds >= 60 ? 1 : 0
        guard stage != lastIdleStage else { return }
        if stage == 0, preferences.mascot, !shell.playing {
            shell.waking = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in self?.shell.waking = false }
        }
        lastIdleStage = stage
        shell.idleSeconds = seconds
    }
}

/// Black silhouette surface: masks the fixed-size host, owns hover/drag routing, and
/// ignores points outside the shared path (the transparent shoulder cutouts and bottom corners).
final class ShellContainer: NSView {
    weak var panel: NotchPanel?
    var hosting: NSView?

    private let mask = CAShapeLayer()
    private let highlight = CAShapeLayer()
    private var geometry = ShellGeometry(width: 188, height: 30, shoulder: 6, bottom: 12)
    private var path: CGPath = CGMutablePath()
    private var hoverInside = false
    private var invalidReported = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.mask = mask
        highlight.fillColor = nil
        highlight.strokeColor = NSColor(red: 0x33 / 255, green: 0xd1 / 255, blue: 0x7a / 255, alpha: 1).cgColor
        highlight.lineWidth = 4
        highlight.zPosition = 10
        highlight.isHidden = true
        layer?.addSublayer(highlight)
        registerForDraggedTypes([.fileURL, .URL, .string])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(_ geometry: ShellGeometry) {
        self.geometry = geometry
        rebuildPath()
    }

    private func rebuildPath() {
        path = NotchShape.path(in: bounds, geometry: geometry)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = bounds
        mask.path = path
        highlight.frame = bounds
        highlight.path = path
        CATransaction.commit()
    }

    func setDragHighlight(_ on: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.isHidden = !on
        CATransaction.commit()
    }

    func containsScreenPoint(_ point: NSPoint) -> Bool {
        guard let window else { return false }
        return path.contains(convert(window.convertPoint(fromScreen: point), from: nil))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard path.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { panel?.reconcilePointer() }
    override func mouseMoved(with event: NSEvent) { panel?.reconcilePointer() }
    override func mouseExited(with event: NSEvent) { panel?.reconcilePointer() }

    func setHoverInside(_ inside: Bool) {
        guard inside != hoverInside else { return }
        hoverInside = inside
        if inside { panel?.pointerEntered() } else { panel?.pointerExited() }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        placeHosting()
        rebuildPath()
    }

    /// Keeps the fixed-size hosting view centered and top-pinned while the silhouette moves.
    func placeHosting() {
        guard let hosting else { return }
        let scale = window?.backingScaleFactor ?? 1
        let x = (((bounds.width - hosting.frame.width) / 2) * scale).rounded() / scale
        hosting.frame.origin = NSPoint(x: x,
                                       y: bounds.height - hosting.frame.height)
    }

    // MARK: Drag destination

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    private func evaluateDrag(_ info: NSDraggingInfo) -> NSDragOperation {
        guard path.contains(convert(info.draggingLocation, from: nil)) else {
            panel?.fileDragEnded()
            return []
        }
        if fileURLs(info).isEmpty {
            if !invalidReported { invalidReported = true; panel?.invalidDragEntered() }
            return []
        }
        panel?.fileDragEntered()
        return .copy
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { evaluateDrag(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { evaluateDrag(sender) }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        invalidReported = false
        panel?.fileDragEnded()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        invalidReported = false
        panel?.fileDragEnded()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard !urls.isEmpty, path.contains(convert(sender.draggingLocation, from: nil)) else { return false }
        panel?.fileDragDropped(urls)
        return true
    }
}
