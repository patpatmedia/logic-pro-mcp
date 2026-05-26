import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Channel that reads and mutates Logic Pro state via the macOS Accessibility API.
/// Primary channel for state queries (transport, tracks, mixer) and UI mutations
/// (clicking mute/solo buttons, reading fader values, etc.)
actor AccessibilityChannel: Channel {
    let id: ChannelID = .accessibility

    func start() async throws {
        // Verify AX trust. If not trusted, the process needs to be added to
        // System Preferences > Privacy & Security > Accessibility.
        let trusted = AXIsProcessTrusted()
        guard trusted else {
            throw AccessibilityError.notTrusted
        }
        guard ProcessUtils.isLogicProRunning else {
            Log.warn("Logic Pro not running at AX channel start", subsystem: "ax")
            return
        }
        Log.info("Accessibility channel started", subsystem: "ax")
    }

    func stop() async {
        Log.info("Accessibility channel stopped", subsystem: "ax")
    }

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        guard ProcessUtils.isLogicProRunning else {
            return .error("Logic Pro is not running")
        }

        switch operation {
        // MARK: - Transport reads
        case "transport.get_state":
            return getTransportState()

        // MARK: - Transport mutations
        case "transport.toggle_cycle":
            return toggleTransportButton(named: "Cycle")
        case "transport.toggle_metronome":
            return toggleTransportButton(named: "Metronome")
        case "transport.set_tempo":
            return setTempo(params: params)
        case "transport.set_cycle_range":
            return setCycleRange(params: params)

        // MARK: - Track reads
        case "track.get_tracks":
            return getTracks()
        case "track.get_selected":
            return getSelectedTrack()

        // MARK: - Track mutations
        case "track.select":
            return selectTrack(params: params)
        case "track.select_add":
            return selectTrackAdditive(params: params)
        case "track.create_stack":
            return createTrackStack(params: params)
        case "track.set_mute":
            return setTrackToggle(params: params, button: "Mute")
        case "track.set_solo":
            return setTrackToggle(params: params, button: "Solo")
        case "track.set_arm":
            return setTrackToggle(params: params, button: "Record")
        case "track.rename":
            return renameTrack(params: params)
        case "track.set_color":
            return .error("Track color setting not supported via AX")

        // MARK: - Mixer reads
        case "mixer.get_state":
            return getMixerState()
        case "mixer.get_channel_strip":
            return getChannelStrip(params: params)

        // MARK: - Mixer mutations
        case "mixer.set_volume":
            return setMixerValue(params: params, target: .volume)
        case "mixer.set_pan":
            return setMixerValue(params: params, target: .pan)
        case "mixer.set_send":
            return .error("Send adjustment not yet implemented via AX")
        case "mixer.set_input", "mixer.set_output":
            return .error("I/O routing not yet implemented via AX")
        case "mixer.toggle_eq":
            return .error("EQ toggle not yet implemented via AX")
        case "mixer.reset_strip":
            return .error("Strip reset not yet implemented via AX")

        // MARK: - Navigation
        case "nav.get_markers":
            return .error("Marker reading not yet implemented via AX")
        case "nav.rename_marker":
            return .error("Marker renaming not yet implemented via AX")

        // MARK: - Project
        case "project.get_info":
            return getProjectInfo()

        // MARK: - Regions
        case "region.get_regions":
            return .error("Region reading not yet implemented via AX")
        case "region.select", "region.loop", "region.set_name", "region.move", "region.resize":
            return .error("Region operations not yet implemented via AX")

        // MARK: - Plugins
        case "plugin.list", "plugin.insert", "plugin.bypass", "plugin.remove":
            return .error("Plugin operations not yet implemented via AX")

        // MARK: - Automation
        case "automation.get_mode":
            return .error("Automation mode reading not yet implemented via AX")
        case "automation.set_mode":
            return .error("Automation mode setting not yet implemented via AX")

        default:
            return .error("Unsupported AX operation: \(operation)")
        }
    }

    func healthCheck() async -> ChannelHealth {
        guard AXIsProcessTrusted() else {
            return .unavailable("Accessibility not trusted — add this process in System Preferences")
        }
        guard ProcessUtils.isLogicProRunning else {
            return .unavailable("Logic Pro is not running")
        }
        // Quick smoke test: can we reach the app root?
        guard AXLogicProElements.appRoot() != nil else {
            return .unavailable("Cannot access Logic Pro AX element")
        }
        return .healthy(detail: "AX connected to Logic Pro")
    }

    // MARK: - Transport

    private func getTransportState() -> ChannelResult {
        guard let transport = AXLogicProElements.getTransportBar() else {
            return .error("Cannot locate transport bar")
        }
        let state = AXValueExtractors.extractTransportState(from: transport)
        return encodeResult(state)
    }

    private func toggleTransportButton(named name: String) -> ChannelResult {
        guard let button = AXLogicProElements.findTransportButton(named: name) else {
            return .error("Cannot find transport button: \(name)")
        }
        guard AXHelpers.performAction(button, kAXPressAction) else {
            return .error("Failed to press transport button: \(name)")
        }
        return .success("{\"toggled\":\"\(name)\"}")
    }

    private func setTempo(params: [String: String]) -> ChannelResult {
        guard let tempoStr = params["tempo"], let _ = Double(tempoStr) else {
            return .error("Missing or invalid 'tempo' parameter")
        }
        guard let transport = AXLogicProElements.getTransportBar() else {
            return .error("Cannot locate transport bar")
        }
        // Find the tempo text field and set its value
        let texts = AXHelpers.findAllDescendants(of: transport, role: kAXTextFieldRole, maxDepth: 4)
        for field in texts {
            let desc = AXHelpers.getDescription(field)?.lowercased() ?? ""
            if desc.contains("tempo") || desc.contains("bpm") {
                AXHelpers.setAttribute(field, kAXValueAttribute, tempoStr as CFTypeRef)
                AXHelpers.performAction(field, kAXConfirmAction)
                return .success("{\"tempo\":\(tempoStr)}")
            }
        }
        return .error("Cannot locate tempo field")
    }

    private func setCycleRange(params: [String: String]) -> ChannelResult {
        // Cycle range setting via AX is fragile — requires locating the cycle locators
        guard let _ = params["start"], let _ = params["end"] else {
            return .error("Missing 'start' and/or 'end' parameters")
        }
        return .error("Cycle range setting not yet fully implemented via AX")
    }

    // MARK: - Tracks

    private func getTracks() -> ChannelResult {
        let headers = AXLogicProElements.allTrackHeaders()
        if headers.isEmpty {
            return .error("No track headers found — is a project open?")
        }
        var tracks: [TrackState] = []
        for (index, header) in headers.enumerated() {
            let track = AXValueExtractors.extractTrackState(from: header, index: index)
            tracks.append(track)
        }
        return encodeResult(tracks)
    }

    private func getSelectedTrack() -> ChannelResult {
        let headers = AXLogicProElements.allTrackHeaders()
        for (index, header) in headers.enumerated() {
            let track = AXValueExtractors.extractTrackState(from: header, index: index)
            if track.isSelected {
                return encodeResult(track)
            }
        }
        return .error("No track is currently selected")
    }

    /// Select a single track. Only a genuine HID-level click changes Logic's track
    /// selection — verified live: setting AXSelected/AXFocused/AXValue, pressing the
    /// "Has Focus" radio, and `postToPid` clicks all leave the selection unchanged.
    /// So we bring Logic to the front and drive a real click (cursor warp + HID tap)
    /// on the header, then VERIFY the selection actually moved.
    private func selectTrack(params: [String: String]) -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr) else {
            return .error("Missing or invalid 'index' parameter")
        }
        guard let header = AXLogicProElements.findTrackHeader(at: index) else {
            return .error("Track at index \(index) not found")
        }
        guard let point = trackClickPoint(header: header, index: index) else {
            return .error("Track \(index) has no screen position (scrolled out of view?)")
        }
        _ = ProcessUtils.activateLogicPro()
        usleep(150_000)
        UIInput.clickGlobal(at: point)
        guard selectionContains(index: index, retries: 6) else {
            return .error(
                "Track \(index): selection click did not take. The track may be "
                + "scrolled out of view (its header must be visible to be clicked)."
            )
        }
        return .success("{\"selected\":\(index)}")
    }

    /// The screen point to click to select a track: the name-field center if available
    /// (a stable, control-free spot), else the upper area of the header row.
    private func trackClickPoint(header: AXUIElement, index: Int) -> CGPoint? {
        if let nameField = AXLogicProElements.findTrackNameField(trackIndex: index),
           let center = AXHelpers.elementCenter(nameField) {
            return center
        }
        guard let frame = AXHelpers.elementFrame(header) else { return nil }
        return CGPoint(x: frame.midX, y: frame.minY + min(14, frame.height * 0.3))
    }

    /// Re-read track headers via the same path as the resource reader and confirm that
    /// the track at `index` is currently selected. Retries because the AX tree lags the
    /// UI commit. Used to verify click-driven (de)selection actually took effect.
    private func selectionContains(index: Int, retries: Int = 0) -> Bool {
        for attempt in 0...max(0, retries) {
            if attempt > 0 { usleep(60_000) }
            let headers = AXLogicProElements.allTrackHeaders()
            guard index >= 0, index < headers.count else { continue }
            let state = AXValueExtractors.extractTrackState(from: headers[index], index: index)
            if state.isSelected { return true }
        }
        return false
    }

    /// Extend the current track selection by Cmd-clicking another track header.
    /// AX cannot mutate selection at all (verified live), so this drives a real
    /// HID-level Cmd-click — the same mechanism `selectTrack` relies on. Verifies
    /// the track ends up selected so a silent miss can't let create_stack proceed
    /// on the wrong set of tracks.
    private func selectTrackAdditive(params: [String: String]) -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr) else {
            return .error("Missing or invalid 'index' parameter")
        }
        guard let header = AXLogicProElements.findTrackHeader(at: index) else {
            return .error("Track at index \(index) not found")
        }
        guard let point = trackClickPoint(header: header, index: index) else {
            return .error("Track \(index) has no screen position (scrolled out of view?)")
        }
        _ = ProcessUtils.activateLogicPro()
        usleep(150_000)
        UIInput.clickGlobal(at: point, flags: .maskCommand)
        guard selectionContains(index: index, retries: 6) else {
            return .error(
                "Track \(index): additive selection click did not take — the track is not "
                + "selected afterwards (its header must be visible to be clicked)."
            )
        }
        return .success("{\"selected_add\":\(index)}")
    }

    /// Collect the indices of all currently-selected tracks (resource-reader path).
    private func currentlySelectedIndices() -> [Int] {
        let headers = AXLogicProElements.allTrackHeaders()
        var result: [Int] = []
        for (i, header) in headers.enumerated() where
            AXValueExtractors.extractTrackState(from: header, index: i).isSelected {
            result.append(i)
        }
        return result
    }

    /// Create a Track Stack from the currently selected tracks. Triggers Logic's
    /// "Create Track Stack" command via a real HID ⌘⇧D (postToPid keys don't register
    /// in Logic), then resolves the type-chooser sheet by picking the Folder/Summing
    /// radio and confirming. Defaults to a Folder Stack.
    ///
    /// SAFETY: when `indices` is supplied, the *actual* selection is verified against
    /// it immediately before triggering — a stale/changed selection aborts the whole
    /// operation rather than turning the wrong track into a stack. We deliberately do
    /// NOT call `activateLogicPro()` here: the selection clicks already brought Logic
    /// to the front, and re-activating was the suspected cause of the selection moving
    /// to the wrong track between selection and trigger.
    private func createTrackStack(params: [String: String]) -> ChannelResult {
        let type = (params["type"] ?? "folder").lowercased()
        let wantSumming = type.contains("sum")

        guard ProcessUtils.logicProPID() != nil else {
            return .error("Logic Pro is not running")
        }

        // SAFETY GATE: confirm the live selection is exactly the requested tracks.
        if let want = params["indices"], !want.isEmpty {
            let requested = Set(want.split(separator: ",").compactMap { Int($0) })
            let actual = Set(currentlySelectedIndices())
            guard requested == actual else {
                return .error(
                    "Aborting create_stack: selection \(actual.sorted()) does not match the "
                    + "requested tracks \(requested.sorted()). Refusing to stack the wrong tracks."
                )
            }
        }

        // Trigger via real HID ⌘⇧D (key code 2 == "D").
        UIInput.keyChordGlobal(2, flags: [.maskCommand, .maskShift])

        // Wait for the type-chooser sheet to appear.
        var sheet: AXUIElement?
        for attempt in 0..<12 {
            usleep(attempt == 0 ? 250_000 : 90_000)
            if let found = AXLogicProElements.frontSheet() {
                sheet = found
                break
            }
        }
        guard let sheet else {
            return .error("Track Stack dialog did not appear after ⌘⇧D — nothing was created.")
        }

        // Pick the requested stack type. Titles are localized, so match on the
        // language-stable fragments ("Summing" / "Folder"|"Ordner"). If the radio
        // can't be found we must NOT press Create — the dialog would commit Logic's
        // default type (Summing), producing the wrong stack. Dismiss and report instead.
        let radios = AXHelpers.findAllDescendants(of: sheet, role: kAXRadioButtonRole, maxDepth: 6)
        guard let target = radios.first(where: { radio in
            let t = (AXHelpers.getTitle(radio) ?? "").lowercased()
            return wantSumming ? t.contains("summing") : (t.contains("folder") || t.contains("ordner"))
        }) else {
            // Escape (key code 53) cancels the type-chooser sheet so nothing is created.
            UIInput.keyChordGlobal(53, flags: [])
            let wanted = wantSumming ? "Summing" : "Folder"
            return .error(
                "Track Stack type radio for \"\(wanted)\" not found in the dialog — "
                + "cancelled to avoid creating the wrong stack type."
            )
        }
        AXHelpers.performAction(target, kAXPressAction)

        // Confirm. Prefer the Create/Erstellen button; fall back to the default
        // button via Return.
        let buttons = AXHelpers.findAllDescendants(of: sheet, role: kAXButtonRole, maxDepth: 6)
        if let createButton = buttons.first(where: { button in
            let t = (AXHelpers.getTitle(button) ?? "").lowercased()
            return t.contains("create") || t.contains("erstell")
        }) {
            AXHelpers.performAction(createButton, kAXPressAction)
        } else {
            UIInput.pressReturn()
        }

        let kind = wantSumming ? "Summing Stack" : "Folder Stack"
        return .success("{\"created_stack\":\"\(kind)\"}")
    }

    private func setTrackToggle(params: [String: String], button buttonName: String) -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr) else {
            return .error("Missing or invalid 'index' parameter")
        }
        let finder: (Int) -> AXUIElement? = switch buttonName {
        case "Mute": AXLogicProElements.findTrackMuteButton
        case "Solo": AXLogicProElements.findTrackSoloButton
        case "Record": AXLogicProElements.findTrackArmButton
        default: { _ in nil }
        }
        guard let button = finder(index) else {
            return .error("Cannot find \(buttonName) button on track \(index)")
        }
        guard AXHelpers.performAction(button, kAXPressAction) else {
            return .error("Failed to click \(buttonName) on track \(index)")
        }
        return .success("{\"track\":\(index),\"toggled\":\"\(buttonName)\"}")
    }

    private func renameTrack(params: [String: String]) -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr),
              let name = params["name"] else {
            return .error("Missing 'index' or 'name' parameter")
        }

        // Strategy 1 (reliable, no synthetic input): direct AX value-set on the name
        // field. This only works when the field is genuinely AX-editable — true for
        // Track Stack masters, FALSE for regular tracks (their label is static text
        // until double-clicked). Gate on settability so we don't fire repeated
        // focus/value sets into a non-editable field — that was the visible focus
        // flicker on regular tracks. Editable fields still get a few retries because a
        // freshly-created master's field isn't ready immediately.
        if let field0 = AXLogicProElements.findTrackNameField(trackIndex: index),
           isAttributeSettable(field0, kAXValueAttribute as String) {
            for attempt in 0..<4 {
                if attempt > 0 { usleep(150_000) }
                guard let field = AXLogicProElements.findTrackNameField(trackIndex: index) else {
                    continue
                }
                AXHelpers.setAttribute(field, kAXFocusedAttribute, kCFBooleanTrue)
                if AXHelpers.setAttribute(field, kAXValueAttribute, name as CFTypeRef) {
                    AXHelpers.performAction(field, kAXConfirmAction)
                    if let result = verifyTrackName(index: index, expected: name, retries: 2) {
                        return result
                    }
                }
            }
        }

        // Strategy 2 (fallback): drive the real UI. CRITICAL: only type after we have
        // CONFIRMED the double-click put a text editor into focus. Otherwise the old code
        // blind-fired Cmd+A ("Select All") + keystrokes straight into Logic — uncontrolled
        // global input that can mangle the project (suspected cause of a stray nested
        // Track Stack). If edit mode isn't entered, abort cleanly instead.
        guard let field = AXLogicProElements.findTrackNameField(trackIndex: index),
              let center = AXHelpers.elementCenter(field) else {
            return .error("Track \(index): name field not found; cannot rename.")
        }
        _ = ProcessUtils.activateLogicPro()
        usleep(80_000)
        // All synthetic input via the HID tap — Logic ignores postToPid mouse/keys.
        UIInput.doubleClickGlobal(at: center)
        usleep(120_000)
        // Confirm an editor is active before typing (so we never blind-fire keystrokes
        // into Logic). Accept any text-like focused role OR the name field reporting
        // focus. Include the observed role in the abort message for diagnosis.
        let focusedEditor = systemFocusedElement()
        let focusRole = focusedEditor.flatMap { AXHelpers.getRole($0) }
        let editing = (focusRole?.lowercased().contains("text") ?? false) || elementIsFocused(field)
        guard editing else {
            return .error(
                "Track \(index): could not confirm rename edit mode (focused role: "
                + "\(focusRole ?? "none")). Aborted without typing to avoid stray keystrokes."
            )
        }

        // Now that edit mode is active, the focused element is a genuine editable text
        // field — set its value via AX directly (the reliable path that works for stack
        // masters). We deliberately do NOT synthesize typing: Logic ignores synthetic
        // Unicode key events for text, and worse, when the field loses focus those
        // keystrokes hit Logic as global commands (observed: window minimizes). So if
        // the AX set doesn't take, cancel edit mode with Escape and abort cleanly.
        if let editor = focusedEditor {
            AXHelpers.setAttribute(editor, kAXValueAttribute, name as CFTypeRef)
            AXHelpers.performAction(editor, kAXConfirmAction)
            if let result = verifyTrackName(index: index, expected: name, retries: 5) {
                return result
            }
        }
        UIInput.keyChordGlobal(53, flags: [])  // Escape: leave edit mode without committing junk
        return .error(
            "Track \(index): could not set the name via AX after entering edit mode "
            + "(focused role: \(focusRole ?? "none")). Aborted without typing."
        )
    }

    /// The system-wide focused UI element (e.g. the rename text-field editor when a
    /// track name is being edited), or nil if none is reported.
    private func systemFocusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success,
            let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else { return nil }
        return (focusedRef as! AXUIElement)
    }

    /// Whether `attribute` is settable on `element` (e.g. kAXValue is settable on a
    /// Track Stack master's editable name field, but not on a regular track's static
    /// label). Used to route rename to the right strategy without firing wasted sets.
    private func isAttributeSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success
        else { return false }
        return settable.boolValue
    }

    /// Whether the given element reports itself as focused (kAXFocused == true).
    private func elementIsFocused(_ element: AXUIElement) -> Bool {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedAttribute as CFString, &ref) == .success
        else { return false }
        return (ref as? Bool) ?? false
    }

    /// Fire AXConfirm on whatever element currently holds focus — after a double-click
    /// into a track name this is the field editor, so confirming it commits the edit
    /// (the same effect as clicking away). No-op if nothing is focused.
    private func confirmFocusedElement() {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success,
            let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else { return }
        AXHelpers.performAction(focusedRef as! AXUIElement, kAXConfirmAction)
    }

    /// Re-read the track via the same path as the resource reader and confirm the name
    /// matches `expected`. Retries a few times because the AX tree lags the UI commit.
    /// Returns a success result on match, or nil so the caller can fall through / fail.
    private func verifyTrackName(index: Int, expected: String, retries: Int = 0) -> ChannelResult? {
        for attempt in 0...max(0, retries) {
            if attempt > 0 { usleep(60_000) }
            guard let header = AXLogicProElements.findTrackHeader(at: index) else {
                continue
            }
            let state = AXValueExtractors.extractTrackState(from: header, index: index)
            if state.name == expected {
                return makeRenameSuccess(index: index, name: expected)
            }
        }
        return nil
    }

    private func makeRenameSuccess(index: Int, name expected: String) -> ChannelResult {
        let escaped = expected
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return .success("{\"track\":\(index),\"name\":\"\(escaped)\",\"verified\":true}")
    }

    // MARK: - Mixer

    private enum MixerTarget {
        case volume
        case pan
    }

    private func getMixerState() -> ChannelResult {
        guard let mixer = AXLogicProElements.getMixerArea() else {
            return .error("Cannot locate mixer — is it visible?")
        }
        let strips = AXHelpers.getChildren(mixer)
        var channelStrips: [ChannelStripState] = []

        for (index, strip) in strips.enumerated() {
            let sliders = AXHelpers.findAllDescendants(of: strip, role: kAXSliderRole, maxDepth: 4)
            let volume = sliders.first.flatMap { AXValueExtractors.extractSliderValue($0) } ?? 0.0
            let pan = sliders.count > 1
                ? AXValueExtractors.extractSliderValue(sliders[1]) ?? 0.0
                : 0.0

            channelStrips.append(ChannelStripState(
                trackIndex: index,
                volume: volume,
                pan: pan
            ))
        }
        return encodeResult(channelStrips)
    }

    private func getChannelStrip(params: [String: String]) -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr) else {
            return .error("Missing or invalid 'index' parameter")
        }
        guard let mixer = AXLogicProElements.getMixerArea() else {
            return .error("Cannot locate mixer — is it visible?")
        }
        let strips = AXHelpers.getChildren(mixer)
        guard index >= 0 && index < strips.count else {
            return .error("Channel strip index \(index) out of range")
        }
        let strip = strips[index]
        let sliders = AXHelpers.findAllDescendants(of: strip, role: kAXSliderRole, maxDepth: 4)
        let volume = sliders.first.flatMap { AXValueExtractors.extractSliderValue($0) } ?? 0.0
        let pan = sliders.count > 1
            ? AXValueExtractors.extractSliderValue(sliders[1]) ?? 0.0
            : 0.0

        let state = ChannelStripState(trackIndex: index, volume: volume, pan: pan)
        return encodeResult(state)
    }

    private func setMixerValue(params: [String: String], target: MixerTarget) -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr),
              let valueStr = params["value"], let value = Double(valueStr) else {
            return .error("Missing 'index' or 'value' parameter")
        }
        let element: AXUIElement?
        switch target {
        case .volume:
            element = AXLogicProElements.findFader(trackIndex: index)
        case .pan:
            element = AXLogicProElements.findPanKnob(trackIndex: index)
        }
        guard let slider = element else {
            return .error("Cannot find \(target) control for track \(index)")
        }
        AXHelpers.setAttribute(slider, kAXValueAttribute, NSNumber(value: value))
        let label = target == .volume ? "volume" : "pan"
        return .success("{\"\(label)\":\(value),\"track\":\(index)}")
    }

    // MARK: - Project

    private func getProjectInfo() -> ChannelResult {
        guard let window = AXLogicProElements.mainWindow() else {
            return .error("Cannot locate Logic Pro main window")
        }
        let title = AXHelpers.getTitle(window) ?? "Unknown"
        var info = ProjectInfo()
        info.name = title
        info.lastUpdated = Date()
        return encodeResult(info)
    }

    // MARK: - JSON encoding

    private func encodeResult<T: Encodable>(_ value: T) -> ChannelResult {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(value)
            guard let json = String(data: data, encoding: .utf8) else {
                return .error("Failed to encode result to UTF-8")
            }
            return .success(json)
        } catch {
            return .error("JSON encoding failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Errors

enum AccessibilityError: Error, CustomStringConvertible {
    case notTrusted

    var description: String {
        switch self {
        case .notTrusted:
            return "Process is not trusted for Accessibility. Add it in System Preferences > Privacy & Security > Accessibility."
        }
    }
}
