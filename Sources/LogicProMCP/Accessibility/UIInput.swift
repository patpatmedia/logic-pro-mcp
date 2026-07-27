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

    /// Scroll by `deltaY` pixels at `point` via the global HID tap. Positive values
    /// scroll the content up (towards the start of the document), i.e. earlier tracks
    /// come into view — the same direction a physical wheel push produces.
    ///
    /// The event is delivered to whatever sits under the *real* cursor, so the cursor is
    /// warped to `point` first. Used to bring a track header into the visible area before
    /// clicking it (Logic only accepts clicks on rows that are actually on screen).
    /// Note: moves the user's actual cursor.
    static func scrollGlobal(at point: CGPoint, deltaY: Int32) {
        guard let source = source() else { return }
        CGWarpMouseCursorPosition(point)
        usleep(20_000)
        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 1,
            wheel1: deltaY,
            wheel2: 0,
            wheel3: 0
        ) else { return }
        event.location = point
        event.post(tap: .cghidEventTap)
        usleep(stepDelay)
    }

    /// Press at `from`, move to `to` in many small steps, release. Logic only recognises
    /// a track-header drag when the movement arrives as a stream of intermediate
    /// positions — a single jump from press to release is ignored.
    /// Note: moves the user's actual cursor.
    static func dragGlobal(
        from: CGPoint,
        to: CGPoint,
        steps: Int = 30,
        stepDelayMicros: useconds_t = 35_000
    ) {
        guard let source = source(), steps > 0 else { return }
        CGWarpMouseCursorPosition(from)
        usleep(120_000)

        post(source, .leftMouseDown, at: from)
        usleep(150_000)

        for step in 1...steps {
            let progress = Double(step) / Double(steps)
            let point = CGPoint(
                x: from.x + (to.x - from.x) * progress,
                y: from.y + (to.y - from.y) * progress
            )
            post(source, .leftMouseDragged, at: point)
            usleep(stepDelayMicros)
        }

        // Settle on the final position before releasing: Logic places the insert marker
        // from the last position it saw, and releasing too early drops the last move.
        usleep(150_000)
        post(source, .leftMouseUp, at: to)
        usleep(250_000)
    }

    private static func post(_ source: CGEventSource, _ type: CGEventType, at point: CGPoint) {
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else { return }
        CGWarpMouseCursorPosition(point)
        event.post(tap: .cghidEventTap)
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
