import CoreGraphics
import Foundation

/// Low-level synthetic mouse/keyboard input via CGEvent.
///
/// Used for the mutations the AX API cannot perform on Logic — most notably moving the
/// track selection and entering a track-name edit field. Logic does NOT register
/// `postToPid` events for these; they only take effect when delivered on the global HID
/// tap (`.cghidEventTap`), exactly like physical input. Callers must therefore bring
/// Logic to the front first (and the mouse helpers move the real cursor).
enum UIInput {
    /// Virtual key codes used here (US layout).
    private enum Key {
        static let `return`: CGKeyCode = 36
    }

    /// Small settle delay (microseconds) between discrete input steps.
    private static let stepDelay: useconds_t = 40_000

    private static func source() -> CGEventSource? {
        CGEventSource(stateID: .hidSystemState)
    }

    /// "Real" click: warp the cursor to `point` and click via the global HID tap, exactly
    /// as a physical click would arrive. This is what Logic's track list accepts as a
    /// genuine selection click (postToPid mouse events don't register). Pass `.maskCommand`
    /// for an additive (Cmd-click) selection. Works across displays (incl. negative coords).
    /// Note: moves the user's actual cursor.
    static func clickGlobal(at point: CGPoint, flags: CGEventFlags = []) {
        guard let source = source() else { return }
        CGWarpMouseCursorPosition(point)
        usleep(20_000)
        for down in [true, false] {
            guard let event = CGEvent(
                mouseEventSource: source,
                mouseType: down ? .leftMouseDown : .leftMouseUp,
                mouseCursorPosition: point,
                mouseButton: .left
            ) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
        usleep(stepDelay)
    }

    /// "Real" double-click via the global HID tap (warps the cursor first). Needed to
    /// enter Logic's track-name edit mode — postToPid double-clicks don't reach Logic.
    /// Note: moves the user's actual cursor.
    static func doubleClickGlobal(at point: CGPoint) {
        guard let source = source() else { return }
        CGWarpMouseCursorPosition(point)
        usleep(20_000)
        for clickState in 1...2 {
            for down in [true, false] {
                guard let event = CGEvent(
                    mouseEventSource: source,
                    mouseType: down ? .leftMouseDown : .leftMouseUp,
                    mouseCursorPosition: point,
                    mouseButton: .left
                ) else { continue }
                event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
                event.post(tap: .cghidEventTap)
            }
            usleep(15_000)
        }
        usleep(stepDelay)
    }

    /// Post a key chord (key + modifier flags) on the global HID tap, delivered to the
    /// frontmost app like a physical key press. Logic ignores `postToPid` key events for
    /// commands such as ⌘⇧D (Create Track Stack), ⌥⌘A (New Audio Track) or Escape.
    static func keyChordGlobal(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        usleep(40_000)
        postKeyGlobal(keyCode, flags: flags)
        usleep(stepDelay)
    }

    /// Commit the current edit (Return). A longer settle precedes the keystroke so the
    /// field editor doesn't drop it after a burst of input.
    static func pressReturn() {
        usleep(120_000)
        postKeyGlobal(Key.return, flags: [])
        usleep(stepDelay)
    }

    /// Post a key on the global HID tap (the frontmost app's key window receives it).
    private static func postKeyGlobal(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let source = source(),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
