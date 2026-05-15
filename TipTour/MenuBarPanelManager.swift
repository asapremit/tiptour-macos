//
//  MenuBarPanelManager.swift
//  TipTour
//
//  Manages the NSStatusItem (menu bar icon) and a custom borderless NSPanel
//  that drops down below it when clicked. The panel hosts a SwiftUI view
//  (CompanionPanelView) via NSHostingView. Uses the same NSPanel pattern as
//  FloatingSessionButton and GlobalPushToTalkOverlay for consistency.
//
//  The panel is non-activating so it does not steal focus from the user's
//  current app, and auto-dismisses when the user clicks outside.
//

import AppKit
import SwiftUI

extension Notification.Name {
    static let tipTourDismissPanel = Notification.Name("tipTourDismissPanel")
    /// Posted by CompanionManager.setPanelPinned when the user toggles
    /// the pushpin. MenuBarPanelManager reinstalls or removes the
    /// click-outside monitor based on the new pinned state, without
    /// hiding the panel.
    static let tipTourPanelPinStateChanged = Notification.Name("tipTourPanelPinStateChanged")
    static let tipTourUserInterfaceClickExecuted = Notification.Name("tipTourUserInterfaceClickExecuted")
}

/// Custom NSPanel subclass that can become the key window even with
/// .nonactivatingPanel style, allowing text fields to receive focus.
private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class MenuBarPanelManager: NSObject {
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var clickOutsideMonitor: Any?
    private var dismissPanelObserver: NSObjectProtocol?
    private var pinStateChangedObserver: NSObjectProtocol?
    /// KVO observation that fires whenever the SwiftUI hosting view's
    /// fitting size changes — e.g. when the user expands the Developer
    /// disclosure section or a workflow checklist appears mid-session.
    /// We resize the NSPanel in response so the new content is fully
    /// visible instead of clipped (or rendering above the panel).
    private var hostingViewSizeObservation: NSKeyValueObservation?

    private let companionManager: CompanionManager
    private let panelWidth: CGFloat = 320
    private let panelHeight: CGFloat = 380

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
        createStatusItem()

        dismissPanelObserver = NotificationCenter.default.addObserver(
            forName: .tipTourDismissPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.hidePanel()
        }

        // When the user toggles the pushpin, reinstall or remove the
        // outside-click monitor live — no need to close and reopen the
        // panel for the change to take effect.
        pinStateChangedObserver = NotificationCenter.default.addObserver(
            forName: .tipTourPanelPinStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            if self.companionManager.isPanelPinned {
                self.removeClickOutsideMonitor()
            } else {
                self.installClickOutsideMonitor()
            }
        }

    }

    deinit {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = dismissPanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = pinStateChangedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Status Item

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem?.button else { return }

        button.image = makeMenuBarIcon()
        button.image?.isTemplate = true
        button.action = #selector(statusItemClicked)
        button.target = self
    }

    /// Draws the same pointer silhouette used by the overlay cursor.
    private func makeMenuBarIcon() -> NSImage {
        let iconSize: CGFloat = 18
        let image = NSImage(size: NSSize(width: iconSize, height: iconSize))
        image.lockFocus()

        let viewBoxSize: CGFloat = 24
        let scale = iconSize * 0.78 / viewBoxSize
        let originX = iconSize * 0.5 - viewBoxSize * scale * 0.5
        let originY = iconSize * 0.5 - viewBoxSize * scale * 0.5

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: originX + x * scale,
                y: originY + (viewBoxSize - y) * scale
            )
        }

        let path = NSBezierPath()
        path.move(to: point(4.037, 4.688))
        path.curve(
            to: point(4.688, 4.037),
            controlPoint1: point(3.90, 3.90),
            controlPoint2: point(3.90, 3.90)
        )
        path.line(to: point(20.688, 10.537))
        path.curve(
            to: point(20.625, 11.484),
            controlPoint1: point(21.42, 10.84),
            controlPoint2: point(21.42, 10.84)
        )
        path.line(to: point(14.501, 13.064))
        path.curve(
            to: point(13.063, 14.499),
            controlPoint1: point(13.43, 13.34),
            controlPoint2: point(13.43, 13.34)
        )
        path.line(to: point(11.484, 20.625))
        path.curve(
            to: point(10.537, 20.688),
            controlPoint1: point(11.17, 21.42),
            controlPoint2: point(11.17, 21.42)
        )
        path.close()

        NSColor.black.setFill()
        path.fill()

        image.unlockFocus()
        return image
    }

    /// Opens the panel automatically on app launch so the user sees
    /// permissions and the start button right away.
    func showPanelOnLaunch() {
        // Small delay so the status item has time to appear in the menu bar
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.showPanel()
        }
    }

    @objc private func statusItemClicked() {
        if let panel, panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    // MARK: - Panel Lifecycle

    private func showPanel() {
        if panel == nil {
            createPanel()
        }

        positionPanelBelowStatusItem()

        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
        installClickOutsideMonitor()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        removeClickOutsideMonitor()
    }

    private func createPanel() {
        let companionPanelView = CompanionPanelView(companionManager: companionManager)
            .frame(width: panelWidth)

        let hostingView = NSHostingView(rootView: companionPanelView)
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        // Have NSHostingView track SwiftUI's preferred size so its
        // `fittingSize` (and `intrinsicContentSize`) update whenever
        // the embedded view's content changes — e.g. when the
        // Developer disclosure expands or a workflow checklist shows.
        // Without this the hosting view stays at the size we gave it
        // at init and SwiftUI renders content beyond the bottom of the
        // panel, which looks like the dropdown is "spilling out above".
        hostingView.sizingOptions = [.intrinsicContentSize]

        let menuBarPanel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        menuBarPanel.isFloatingPanel = true
        menuBarPanel.level = .floating
        menuBarPanel.isOpaque = false
        menuBarPanel.backgroundColor = .clear
        menuBarPanel.hasShadow = false
        menuBarPanel.hidesOnDeactivate = false
        menuBarPanel.isExcludedFromWindowsMenu = true
        menuBarPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        menuBarPanel.isMovableByWindowBackground = false
        menuBarPanel.titleVisibility = .hidden
        menuBarPanel.titlebarAppearsTransparent = true

        menuBarPanel.contentView = hostingView
        panel = menuBarPanel

        // Resize the NSPanel any time the SwiftUI content's fitting size
        // changes. KVO fires on the main thread; `setFrame` here keeps
        // the bottom edge anchored under the menu bar by recomputing
        // origin.y (smaller content → larger origin.y → panel sits flush
        // with the menu bar even after collapsing).
        hostingViewSizeObservation = hostingView.observe(\.fittingSize, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                // Only react to live size changes after the panel is on
                // screen. Initial sizing during showPanel() goes through
                // positionPanelBelowStatusItem() before the panel becomes
                // visible — that path needs to position regardless.
                guard let panel = self?.panel, panel.isVisible else { return }
                self?.repositionPanelToMatchContentSize()
            }
        }
    }

    /// Recompute the panel's frame from the hosting view's current
    /// `fittingSize`. Anchors the top edge directly under the menu bar
    /// (gap stays constant) so the panel grows downward when content
    /// expands and shrinks back up when it collapses.
    private func repositionPanelToMatchContentSize() {
        guard let panel else { return }
        guard let buttonWindow = statusItem?.button?.window else { return }
        guard let contentView = panel.contentView else { return }

        let statusItemFrame = buttonWindow.frame
        let gapBelowMenuBar: CGFloat = 4

        let fittingSize = contentView.fittingSize
        let actualPanelHeight = max(fittingSize.height, 1)

        let panelOriginX = statusItemFrame.midX - (panelWidth / 2)
        let panelOriginY = statusItemFrame.minY - actualPanelHeight - gapBelowMenuBar

        panel.setFrame(
            NSRect(x: panelOriginX, y: panelOriginY, width: panelWidth, height: actualPanelHeight),
            display: true,
            animate: false
        )
    }

    private func positionPanelBelowStatusItem() {
        // Initial sizing on show — same math as the live KVO-driven
        // resize so the first frame is correct before content shifts.
        repositionPanelToMatchContentSize()
    }

    // MARK: - Click Outside Dismissal

    /// Installs a global event monitor that hides the panel when the user clicks
    /// anywhere outside it — the same transient dismissal behavior as NSPopover.
    /// Uses a short delay so that system permission dialogs (triggered by Grant
    /// buttons in the panel) don't immediately dismiss the panel when they appear.
    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()

        // Respect the user's pin preference — when pinned, the panel
        // should behave like a regular workspace window and ignore
        // outside clicks entirely.
        if companionManager.isPanelPinned {
            return
        }

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, let panel = self.panel else { return }

            // Check if the click is inside the status item button — if so, the
            // statusItemClicked handler will toggle the panel, so don't also hide.
            let clickLocation = NSEvent.mouseLocation
            if panel.frame.contains(clickLocation) {
                return
            }

            // Delay dismissal slightly to avoid closing the panel when
            // a system permission dialog appears (e.g. microphone access).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard panel.isVisible else { return }

                // If permissions aren't all granted yet, a system dialog
                // may have focus — don't dismiss during onboarding.
                if !self.companionManager.allPermissionsGranted && !NSApp.isActive {
                    return
                }

                self.hidePanel()
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }
}
