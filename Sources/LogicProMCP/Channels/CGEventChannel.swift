import CoreGraphics
import Foundation

/// Channel that sends keyboard shortcuts to Logic Pro via CGEvent.
/// Uses CGEvent.postToPid() to deliver keystrokes directly without requiring window focus.
/// This is the primary channel for transport control and editing operations.
actor CGEventChannel: Channel {
    let id: ChannelID = .cgEvent

    /// A keyboard shortcut definition.
    private struct Shortcut: Sendable {
        let keyCode: CGKeyCode
        let flags: CGEventFlags

        static func key(_ code: CGKeyCode) -> Shortcut {
            Shortcut(keyCode: code, flags: [])
        }

        static func cmd(_ code: CGKeyCode) -> Shortcut {
            Shortcut(keyCode: code, flags: .maskCommand)
        }

        static func cmdShift(_ code: CGKeyCode) -> Shortcut {
            Shortcut(keyCode: code, flags: [.maskCommand, .maskShift])
        }

        static func option(_ code: CGKeyCode) -> Shortcut {
            Shortcut(keyCode: code, flags: .maskAlternate)
        }

        static func cmdOption(_ code: CGKeyCode) -> Shortcut {
            Shortcut(keyCode: code, flags: [.maskCommand, .maskAlternate])
        }
    }

    /// Mapping from operation strings to keyboard shortcuts.
    /// Key codes: https://developer.apple.com/documentation/coregraphics/cgkeycode
    private static let keyMap: [String: Shortcut] = [
        // Transport
        "transport.play":             .key(49),         // Space
        "transport.stop":             .key(49),         // Space (toggles)
        "transport.record":           .key(15),         // R
        "transport.pause":            .key(49),         // Space
        "transport.rewind":           .key(123),        // Left arrow
        "transport.fast_forward":     .key(124),        // Right arrow
        "transport.toggle_cycle":     .key(8),          // C
        "transport.toggle_metronome": .key(40),         // K
        "transport.goto_position":    .key(47),         // / (opens Go To Position)

        // Editing
        "edit.undo":                  .cmd(6),          // Cmd+Z
        "edit.redo":                  .cmdShift(6),     // Cmd+Shift+Z
        "edit.cut":                   .cmd(7),          // Cmd+X
        "edit.copy":                  .cmd(8),          // Cmd+C
        "edit.paste":                 .cmd(9),          // Cmd+V
        "edit.delete":                .key(51),         // Delete
        "edit.select_all":            .cmd(0),          // Cmd+A
        "edit.split":                 .cmd(17),         // Cmd+T

        // Views
        "view.toggle_mixer":          .key(7),          // X
        "view.toggle_piano_roll":     .key(35),         // P
        "view.toggle_library":        .key(16),         // Y
        "view.toggle_inspector":      .key(34),         // I
        "view.toggle_score_editor":   .cmdOption(35),   // Cmd+Option+P (approximate)
        "view.toggle_step_editor":    .cmdOption(34),   // Cmd+Option+I (approximate)

        // Project
        "project.save":               .cmd(1),          // Cmd+S
        "project.save_as":            .cmdShift(1),     // Cmd+Shift+S
        "project.close":              .cmd(13),         // Cmd+W

        // Track creation
        "track.create_audio":         .cmdOption(0),    // Option+Cmd+A
        "track.create_instrument":    .cmdOption(1),    // Option+Cmd+S
        "track.duplicate":            .cmd(2),          // Cmd+D
        "track.delete":               .cmd(51),         // Cmd+Delete

        // Navigation
        "nav.create_marker":          .cmdOption(39),   // (approximate)
        "nav.zoom_to_fit":            .key(6),          // Z
        "nav.zoom_in":                .cmd(124),        // Cmd+Right — zoom in horizontally
        "nav.zoom_out":               .cmd(123),        // Cmd+Left  — zoom out horizontally
        "nav.zoom_in_vertical":       .cmd(125),        // Cmd+Down  — taller tracks
        "nav.zoom_out_vertical":      .cmd(126),        // Cmd+Up    — shorter tracks
        "edit.join":                  .cmd(38),         // Cmd+J
        "edit.quantize":              .key(44),         // Q (approximate)
        "edit.bounce_in_place":       .cmdOption(11),   // (approximate)

        // Automation
        "automation.toggle_view":     .key(0),          // A
    ]

    func start() async throws {
        guard ProcessUtils.isLogicProRunning else {
            Log.warn("Logic Pro not running at CGEvent channel start", subsystem: "cgEvent")
            return
        }
        Log.info("CGEvent channel started", subsystem: "cgEvent")
    }

    func stop() async {
        Log.info("CGEvent channel stopped", subsystem: "cgEvent")
    }

    /// The observable effect a key command must have to count as successful.
    ///
    /// `sent: true` only ever meant "an event left this process". Logic silently drops
    /// key commands whenever the focus sits somewhere unexpected, so a caller that
    /// believed `sent` went on to work with track indices that didn't exist. For every
    /// command whose effect is cheaply observable via AX we now check the effect itself
    /// and report a real error when nothing happened.
    private enum Effect: Sendable {
        /// A new track row must appear (create_*, duplicate).
        case trackCountIncrease
        /// A track row must disappear (delete).
        case trackCountDecrease
        /// Track rows must change height (vertical zoom).
        case rowHeightChange
    }

    private static let verifiedEffects: [String: Effect] = [
        "track.create_audio":      .trackCountIncrease,
        "track.create_instrument": .trackCountIncrease,
        "track.duplicate":         .trackCountIncrease,
        "track.delete":            .trackCountDecrease,
        "nav.zoom_in_vertical":    .rowHeightChange,
        "nav.zoom_out_vertical":   .rowHeightChange,
    ]

    /// How long to wait for the effect to show up in the AX tree.
    private static let verifyAttempts = 16
    private static let verifyStepMicros: useconds_t = 100_000

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        guard let pid = ProcessUtils.logicProPID() else {
            return .error("Logic Pro is not running")
        }

        guard let shortcut = Self.keyMap[operation] else {
            return .error("No keyboard shortcut mapped for: \(operation)")
        }

        // A modal alert swallows every keystroke. Report it up front — this used to
        // surface as an unrelated error deep in whichever command ran next.
        if let blocked = BlockingDialog.blockingMessage() {
            return .error(blocked)
        }

        guard let effect = Self.verifiedEffects[operation] else {
            let sent = postKeyEvent(keyCode: shortcut.keyCode, flags: shortcut.flags, pid: pid)
            return sent
                ? .success("{\"operation\":\"\(operation)\",\"sent\":true}")
                : .error("Failed to post CGEvent for \(operation)")
        }

        let before = Self.measure(effect)
        guard postKeyEvent(keyCode: shortcut.keyCode, flags: shortcut.flags, pid: pid) else {
            return .error("Failed to post CGEvent for \(operation)")
        }

        for attempt in 0..<Self.verifyAttempts {
            usleep(Self.verifyStepMicros)
            let now = Self.measure(effect)
            if Self.satisfies(effect, before: before, after: now) {
                Log.debug("\(operation) verified after \(attempt + 1) checks", subsystem: "cgEvent")
                return .success(Self.successJSON(operation: operation, effect: effect, value: now))
            }
        }

        return .error(Self.failureMessage(operation: operation, effect: effect, before: before))
    }

    // MARK: - Effect verification

    /// The current value of whatever `effect` observes.
    private static func measure(_ effect: Effect) -> Double {
        switch effect {
        case .trackCountIncrease, .trackCountDecrease:
            return Double(AXLogicProElements.allTrackHeaders().count)
        case .rowHeightChange:
            return AXLogicProElements.trackRowFrame(at: 0).map { Double($0.height) } ?? 0
        }
    }

    private static func satisfies(_ effect: Effect, before: Double, after: Double) -> Bool {
        switch effect {
        case .trackCountIncrease: return after > before
        case .trackCountDecrease: return after < before
        case .rowHeightChange:    return abs(after - before) >= 1
        }
    }

    private static func successJSON(operation: String, effect: Effect, value: Double) -> String {
        switch effect {
        case .trackCountIncrease, .trackCountDecrease:
            return "{\"operation\":\"\(operation)\",\"verified\":true,\"track_count\":\(Int(value))}"
        case .rowHeightChange:
            return "{\"operation\":\"\(operation)\",\"verified\":true,"
                + "\"track_row_height\":\(Int(value))}"
        }
    }

    /// Explain *what did not happen*, and make clear nothing changed — a caller must not
    /// go on to address a track that was never created.
    private static func failureMessage(operation: String, effect: Effect, before: Double) -> String {
        let waited = String(
            format: "%.1f s", Double(verifyAttempts) * Double(verifyStepMicros) / 1_000_000
        )
        var message: String
        switch effect {
        case .trackCountIncrease:
            message = "\(operation) had no effect: the track count is still \(Int(before)) after "
                + "\(waited) — no track was created. Nothing changed, so do not assume any new "
                + "track index."
        case .trackCountDecrease:
            message = "\(operation) had no effect: the track count is still \(Int(before)) after "
                + "\(waited) — no track was deleted."
        case .rowHeightChange:
            message = "\(operation) had no effect: the track row height is still \(Int(before)) px "
                + "after \(waited). Logic only accepts the zoom key command while the arrange "
                + "area has the keyboard focus — click into the arrange area and retry."
        }
        // The most common cause of a swallowed key command, worth naming explicitly.
        if let blocked = BlockingDialog.blockingMessage() {
            message += " " + blocked
        }
        return message
    }

    func healthCheck() async -> ChannelHealth {
        guard ProcessUtils.isLogicProRunning else {
            return .unavailable("Logic Pro is not running")
        }
        guard ProcessUtils.logicProPID() != nil else {
            return .unavailable("Cannot determine Logic Pro PID")
        }
        return .healthy(detail: "CGEvent ready")
    }

    // MARK: - Event Posting

    /// Post a key-down/key-up pair as a real key press. Logic does NOT register
    /// `postToPid` key events (verified live — same reason track selection clicks and
    /// ⌘⇧D must use the HID tap); they have to arrive on the global HID tap exactly like
    /// a physical key press. That delivers to the frontmost app, so Logic is activated
    /// first. `pid` is kept for the activation/log only.
    private func postKeyEvent(keyCode: CGKeyCode, flags: CGEventFlags, pid: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            Log.error("Failed to create CGEventSource", subsystem: "cgEvent")
            return false
        }

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            Log.error("Failed to create CGEvent for keyCode \(keyCode)", subsystem: "cgEvent")
            return false
        }

        keyDown.flags = flags
        keyUp.flags = flags

        // Bring Logic to the front so the HID-tap key press lands in it.
        _ = ProcessUtils.activateLogicPro()
        usleep(120_000)
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        Log.debug("Posted key \(keyCode) flags \(flags.rawValue) via HID tap (Logic pid \(pid))", subsystem: "cgEvent")
        return true
    }
}
