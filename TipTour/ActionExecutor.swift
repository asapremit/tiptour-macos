//
//  ActionExecutor.swift
//  TipTour
//
//  Posts synthetic input events (mouse clicks, keyboard shortcuts,
//  text typing) to drive the user's macOS apps when Autopilot mode is
//  enabled. In Teaching mode (the default), TipTour only POINTS — the
//  user clicks themselves. In Autopilot mode, this executor takes over
//  and clicks for them.
//
//  Why CGEvent at the HID level:
//    `CGEvent.tapEnable(...)` posted to `.cghidEventTap` looks like real
//    hardware input to the OS — apps that gate behavior on input source
//    (some games, secure text fields, screen-recording prompts) accept
//    these where AppleScript / `NSAccessibility.performAction` would
//    silently no-op.
//
//  Why we activate the target app first:
//    `CGEventPostToPid` is broken for clicks (Apple Forum 724835) — it
//    routes the click to the PID's queue but many apps don't process
//    HID events from the queue when not frontmost. Reliable click
//    delivery means: (1) activate the target NSRunningApplication, (2)
//    nudge the cursor, (3) post the click pair to HID.
//
//  Why typing is paste-based:
//    Synthesizing a keystroke per character is fragile across keyboard
//    layouts (a non-US layout where 'q' is a different key code will
//    type the wrong letter). Pasting the text via Cmd+V is layout-
//    agnostic and ~100× faster for long strings.
//

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// Errors the executor can surface to its caller.
enum ActionExecutorError: Error, LocalizedError {
    case accessibilityPermissionMissing
    case unparseableKeyboardShortcut(String)
    case keyCodeNotFoundForCharacter(Character)
    case targetAppNotRunning(String)

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionMissing:
            return "Accessibility permission is required to post synthetic input events."
        case .unparseableKeyboardShortcut(let s):
            return "Couldn't parse keyboard shortcut \"\(s)\"."
        case .keyCodeNotFoundForCharacter(let c):
            return "Don't know how to map character '\(c)' to a key code."
        case .targetAppNotRunning(let name):
            return "Target app \"\(name)\" isn't running."
        }
    }
}

@MainActor
final class ActionExecutor {

    static let shared = ActionExecutor()

    /// How long to wait between mouse-down and mouse-up. Real hardware
    /// clicks are typically 30-80ms apart; some apps (especially Cocoa
    /// menus) reject zero-duration clicks as "phantom" input.
    private let mouseDownToUpDelaySeconds: TimeInterval = 0.045

    /// How long to wait after activating an app before posting the
    /// click to HID. The activation isn't synchronous — focus needs a
    /// few frames to land, especially on Electron apps that animate
    /// window focus changes.
    private let postActivationSettleSeconds: TimeInterval = 0.08

    /// How long to wait between cursor move and the click pair. Some
    /// apps require a hover before they treat a click as legitimate.
    private let postMoveSettleSeconds: TimeInterval = 0.025

    /// How long to wait between keystrokes when synthesizing a multi-key
    /// shortcut. Too short and the system can drop modifier flags.
    private let interKeystrokeDelaySeconds: TimeInterval = 0.012

    // MARK: - Public API

    /// Single primary-button click at the given global AppKit-screen
    /// point. Optionally activates `targetApp` first to make sure the
    /// click is delivered to the right window (prevents the click from
    /// being routed to TipTour's own panel in fringe cases).
    func click(
        atGlobalScreenPoint globalScreenPoint: CGPoint,
        activatingTargetApp targetApp: NSRunningApplication? = nil
    ) async throws {
        try assertAccessibilityPermissionGranted()

        if let targetApp {
            // Bring the target app forward. activate() is the modern
            // replacement for the deprecated activate(options:) — in
            // older SDKs we'd pass .activateIgnoringOtherApps.
            targetApp.activate()
            try await sleepFor(seconds: postActivationSettleSeconds)
        }

        let pointInCoreGraphicsCoordinates = convertGlobalScreenPointToCoreGraphicsPoint(globalScreenPoint)

        // Move the cursor first. A hover-before-click sequence is what
        // real users do, and many apps gate their click handlers on
        // having seen a hover (think hover tooltips that arm the click
        // target). Without this nudge, the click can land but be
        // interpreted as a phantom event.
        if let move = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: pointInCoreGraphicsCoordinates,
            mouseButton: .left
        ) {
            move.post(tap: .cghidEventTap)
        }
        try await sleepFor(seconds: postMoveSettleSeconds)

        // Mouse-down then mouse-up. Setting `mouseEventClickState = 1`
        // marks this as a single-click (the default 0 silently fails
        // for some apps that filter on click-state).
        if let down = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: pointInCoreGraphicsCoordinates,
            mouseButton: .left
        ) {
            down.setIntegerValueField(.mouseEventClickState, value: 1)
            down.post(tap: .cghidEventTap)
        }
        try await sleepFor(seconds: mouseDownToUpDelaySeconds)
        if let up = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: pointInCoreGraphicsCoordinates,
            mouseButton: .left
        ) {
            up.setIntegerValueField(.mouseEventClickState, value: 1)
            up.post(tap: .cghidEventTap)
        }
        print("[ActionExecutor] clicked at global point \(globalScreenPoint)")
    }

    /// Press a keyboard shortcut like "Cmd+S", "Cmd+Shift+N",
    /// "Ctrl+Option+Space". Modifier names are case-insensitive and
    /// aliases are supported (Cmd / Command / ⌘, Opt / Option / Alt /
    /// ⌥, Ctrl / Control / ⌃, Shift / ⇧, Fn).
    func pressKeyboardShortcut(
        _ shortcutString: String,
        activatingTargetApp targetApp: NSRunningApplication? = nil
    ) async throws {
        try assertAccessibilityPermissionGranted()

        let parsed = try parseKeyboardShortcut(shortcutString)

        if let targetApp {
            targetApp.activate()
            try await sleepFor(seconds: postActivationSettleSeconds)
        }

        let source = CGEventSource(stateID: .hidSystemState)

        // Press modifiers in a stable order — control, option, shift,
        // command — which is the order most macOS apps inspect. The
        // exact order doesn't change semantics, but consistency is good
        // for muscle memory of debugging traces.
        guard let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(parsed.virtualKeyCode),
            keyDown: true
        ),
        let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(parsed.virtualKeyCode),
            keyDown: false
        ) else {
            throw ActionExecutorError.unparseableKeyboardShortcut(shortcutString)
        }
        keyDown.flags = parsed.modifierFlags
        keyUp.flags = parsed.modifierFlags

        keyDown.post(tap: .cghidEventTap)
        try await sleepFor(seconds: interKeystrokeDelaySeconds)
        keyUp.post(tap: .cghidEventTap)
        print("[ActionExecutor] pressed shortcut \"\(shortcutString)\" (vk=\(parsed.virtualKeyCode) flags=\(parsed.modifierFlags.rawValue))")
    }

    /// Type `text` into the focused element by staging it on the
    /// pasteboard and synthesizing Cmd+V. Layout-agnostic and ~100×
    /// faster for long strings than per-character key codes.
    ///
    /// Restores the previous pasteboard contents after the paste —
    /// keeps the user's clipboard state intact even when autopilot
    /// types on their behalf.
    func typeText(
        _ text: String,
        activatingTargetApp targetApp: NSRunningApplication? = nil
    ) async throws {
        try assertAccessibilityPermissionGranted()

        if let targetApp {
            targetApp.activate()
            try await sleepFor(seconds: postActivationSettleSeconds)
        }

        let pasteboard = NSPasteboard.general
        // Snapshot prior clipboard contents (string only — we don't
        // attempt to preserve images/files, which would require
        // copying every type and rounds-trips the user is unlikely to
        // care about for a typing autopilot use case).
        let previousClipboardString = pasteboard.string(forType: .string)
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(text, forType: .string)

        // Tiny pause — without this, paste sometimes fires before the
        // pasteboard has finalized the new contents.
        try await sleepFor(seconds: 0.02)

        try await pressKeyboardShortcut("Cmd+V")

        // Wait for the paste to be consumed, then restore the prior
        // string. 0.15s is enough for every native macOS app I've
        // tested; longer-than-strictly-necessary is fine because the
        // user can't see the clipboard.
        try await sleepFor(seconds: 0.15)
        if let previous = previousClipboardString {
            pasteboard.declareTypes([.string], owner: nil)
            pasteboard.setString(previous, forType: .string)
        }
        print("[ActionExecutor] typed \(text.count) characters via paste")
    }

    // MARK: - Permission

    private func assertAccessibilityPermissionGranted() throws {
        if !AXIsProcessTrusted() {
            throw ActionExecutorError.accessibilityPermissionMissing
        }
    }

    // MARK: - Coordinate Conversion

    /// Convert a global AppKit point (bottom-left origin, Y upward) to
    /// a Core Graphics point (top-left origin, Y downward) for posting
    /// to event taps. This is the same conversion `ClickDetector` does
    /// in reverse.
    private func convertGlobalScreenPointToCoreGraphicsPoint(_ globalScreenPoint: CGPoint) -> CGPoint {
        guard let primaryScreen = NSScreen.screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.main else {
            return globalScreenPoint
        }
        let primaryScreenHeight = primaryScreen.frame.height
        return CGPoint(
            x: globalScreenPoint.x,
            y: primaryScreenHeight - globalScreenPoint.y
        )
    }

    // MARK: - Shortcut Parsing

    /// Parsed form of a "Cmd+Shift+N" string.
    private struct ParsedKeyboardShortcut {
        let virtualKeyCode: Int
        let modifierFlags: CGEventFlags
    }

    /// Parse "Cmd+Shift+N" / "Ctrl+Option+Space" into a key code +
    /// modifier flags pair we can hand to CGEvent. Tolerates extra
    /// whitespace, mixed casing, and Unicode glyph aliases (⌘, ⌥, ⌃,
    /// ⇧).
    private func parseKeyboardShortcut(_ shortcutString: String) throws -> ParsedKeyboardShortcut {
        // Split on '+' or '-' separators with surrounding whitespace
        // tolerated.
        let tokens = shortcutString
            .split(whereSeparator: { $0 == "+" || $0 == "-" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else {
            throw ActionExecutorError.unparseableKeyboardShortcut(shortcutString)
        }

        var modifierFlags: CGEventFlags = []
        var keyToken: String?

        for token in tokens {
            let lower = token.lowercased()
            switch lower {
            case "cmd", "command", "⌘":
                modifierFlags.insert(.maskCommand)
            case "opt", "option", "alt", "⌥":
                modifierFlags.insert(.maskAlternate)
            case "ctrl", "control", "⌃":
                modifierFlags.insert(.maskControl)
            case "shift", "⇧":
                modifierFlags.insert(.maskShift)
            case "fn":
                modifierFlags.insert(.maskSecondaryFn)
            default:
                if keyToken != nil {
                    // Two non-modifier tokens — ambiguous (e.g. "Cmd+S+N").
                    throw ActionExecutorError.unparseableKeyboardShortcut(shortcutString)
                }
                keyToken = token
            }
        }

        guard let keyToken else {
            throw ActionExecutorError.unparseableKeyboardShortcut(shortcutString)
        }

        let virtualKeyCode = try virtualKeyCodeForToken(keyToken)
        return ParsedKeyboardShortcut(
            virtualKeyCode: virtualKeyCode,
            modifierFlags: modifierFlags
        )
    }

    /// Map a single-key token like "S", "Space", "Return" to a Carbon
    /// virtual key code. Single-character tokens fall back to the
    /// US-QWERTY layout — Gemini emits shortcuts in the form English
    /// users describe them, regardless of the user's actual layout.
    private func virtualKeyCodeForToken(_ token: String) throws -> Int {
        let lower = token.lowercased()

        // Named keys — covers everything not directly typeable as a
        // character. Keep this map small and explicit so we don't end
        // up debugging a wrong-key autopilot click later.
        let namedKeys: [String: Int] = [
            "space":      kVK_Space,
            "return":     kVK_Return,
            "enter":      kVK_Return,
            "tab":        kVK_Tab,
            "escape":     kVK_Escape,
            "esc":        kVK_Escape,
            "delete":     kVK_Delete,
            "backspace":  kVK_Delete,
            "fwddelete":  kVK_ForwardDelete,
            "forwarddelete": kVK_ForwardDelete,
            "left":       kVK_LeftArrow,
            "right":      kVK_RightArrow,
            "up":         kVK_UpArrow,
            "down":       kVK_DownArrow,
            "home":       kVK_Home,
            "end":        kVK_End,
            "pageup":     kVK_PageUp,
            "pagedown":   kVK_PageDown,
            "f1":         kVK_F1,
            "f2":         kVK_F2,
            "f3":         kVK_F3,
            "f4":         kVK_F4,
            "f5":         kVK_F5,
            "f6":         kVK_F6,
            "f7":         kVK_F7,
            "f8":         kVK_F8,
            "f9":         kVK_F9,
            "f10":        kVK_F10,
            "f11":        kVK_F11,
            "f12":        kVK_F12
        ]
        if let mapped = namedKeys[lower] { return mapped }

        // Single ASCII character → US-QWERTY virtual key code.
        guard let firstCharacter = lower.first, lower.count == 1 else {
            throw ActionExecutorError.unparseableKeyboardShortcut(token)
        }
        if let mapped = Self.usQwertyKeyCodeForCharacter[firstCharacter] {
            return mapped
        }
        throw ActionExecutorError.keyCodeNotFoundForCharacter(firstCharacter)
    }

    /// US-QWERTY layout — covers letters, digits, and the most common
    /// printable punctuation. Anything beyond this should be passed to
    /// `typeText` (paste-based, layout-agnostic) instead of pressed as
    /// a keystroke.
    private static let usQwertyKeyCodeForCharacter: [Character: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
        "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
        "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
        "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
        "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash,
        ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote,
        "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
        "\\": kVK_ANSI_Backslash, "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal,
        "`": kVK_ANSI_Grave
    ]

    // MARK: - Sleep Helper

    private func sleepFor(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
