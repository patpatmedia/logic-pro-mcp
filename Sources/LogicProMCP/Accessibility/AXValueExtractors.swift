import ApplicationServices
import Foundation

/// Extract typed values from AX elements.
/// These handle the various ways Logic Pro represents values in its AX tree.
enum AXValueExtractors {
    /// Extract a numeric value from a slider (volume fader, pan knob, etc.)
    /// Returns the AXValue as a Double, or nil if unavailable.
    static func extractSliderValue(_ element: AXUIElement) -> Double? {
        guard let value = AXHelpers.getValue(element) else { return nil }
        // AXSlider values can come as NSNumber or CFNumber
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        // Try string-based value and parse
        if let str = value as? String, let parsed = Double(str) {
            return parsed
        }
        return nil
    }

    /// Extract a text value from a static text or text field element.
    /// Used for tempo display, position readout, track names, etc.
    static func extractTextValue(_ element: AXUIElement) -> String? {
        // Try kAXValueAttribute first (text fields, static text)
        if let value = AXHelpers.getValue(element) as? String {
            return value
        }
        // Fallback to kAXTitleAttribute
        return AXHelpers.getTitle(element)
    }

    /// Extract a boolean state from a button or checkbox element.
    /// For toggle buttons (mute, solo, arm, cycle, metronome), the value
    /// indicates pressed/active state.
    static func extractButtonState(_ element: AXUIElement) -> Bool? {
        guard let value = AXHelpers.getValue(element) else { return nil }
        // Toggle buttons typically report 0/1 as NSNumber
        if let number = value as? NSNumber {
            return number.boolValue
        }
        // Some buttons use string "1"/"0"
        if let str = value as? String {
            return str == "1" || str.lowercased() == "true"
        }
        return nil
    }

    /// Extract checkbox state (a variant of button state, but checks kAXValueAttribute specifically).
    static func extractCheckboxState(_ element: AXUIElement) -> Bool? {
        guard let value: AnyObject = AXHelpers.getAttribute(element, kAXValueAttribute) else {
            return nil
        }
        if let number = value as? NSNumber {
            return number.intValue != 0
        }
        return nil
    }

    /// Extract the selected state of an element.
    static func extractSelectedState(_ element: AXUIElement) -> Bool? {
        guard let value: AnyObject = AXHelpers.getAttribute(element, kAXSelectedAttribute) else {
            return nil
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return nil
    }

    /// Extract slider range (min/max) for interpreting fader values.
    struct SliderRange {
        let min: Double
        let max: Double
    }

    static func extractSliderRange(_ element: AXUIElement) -> SliderRange? {
        guard let minVal: AnyObject = AXHelpers.getAttribute(element, kAXMinValueAttribute),
              let maxVal: AnyObject = AXHelpers.getAttribute(element, kAXMaxValueAttribute),
              let min = (minVal as? NSNumber)?.doubleValue,
              let max = (maxVal as? NSNumber)?.doubleValue else {
            return nil
        }
        return SliderRange(min: min, max: max)
    }

    /// Read a track header (AXLayoutItem) and extract its basic state.
    static func extractTrackState(from header: AXUIElement, index: Int) -> TrackState {
        let name = extractTrackName(from: header)
        let muted = extractCheckboxByDescription(from: header, description: "Mute") ?? false
        let soloed = extractCheckboxByDescription(from: header, description: "Solo") ?? false
        let armed = extractCheckboxByDescription(from: header, description: "Record Enable") ?? false
        let selected = extractTrackFocusState(from: header)
        let trackType = inferTrackType(from: header, name: name)
        let (volume, pan) = extractTrackVolumePan(from: header)

        return TrackState(
            id: index,
            name: name,
            type: trackType,
            isMuted: muted,
            isSoloed: soloed,
            isArmed: armed,
            isSelected: selected,
            volume: volume,
            pan: pan,
            color: extractTrackColor(from: header)
        )
    }

    /// Read control-bar elements and build a TransportState.
    ///
    /// Verified against Logic 12.3's actual AX tree, which does not match what this used
    /// to assume: the transport toggles are **AXCheckBox** elements (only Stop is an
    /// AXButton), and tempo/playhead position are **AXSliders** inside the LCD display
    /// group — not AXStaticTexts. Searching for buttons and static texts found nothing at
    /// all, which is why every transport read failed silently and
    /// `transport_age_sec` never advanced past "never".
    static func extractTransportState(from transport: AXUIElement) -> TransportState {
        var state = TransportState()

        for toggle in AXHelpers.findAllDescendants(of: transport, role: kAXCheckBoxRole, maxDepth: 4) {
            guard let desc = AXHelpers.getDescription(toggle)?.lowercased() else { continue }
            let on = extractCheckboxState(toggle) ?? false
            switch desc {
            case "play": state.isPlaying = on
            case "record": state.isRecording = on
            case "cycle": state.isCycleEnabled = on
            // "Metronome Click" in Logic 12.3.
            case let d where d.hasPrefix("metronome"): state.isMetronomeEnabled = on
            default: break
            }
        }

        // LCD display: AXSlider desc="Tempo", plus one slider per playhead-position field
        // ("bar", "beat", …). Logic exposes only the fields of the ruler's current display
        // mode, so a missing field stays nil rather than being invented.
        var positionFields: [String: Int] = [:]
        for slider in AXHelpers.findAllDescendants(of: transport, role: kAXSliderRole, maxDepth: 5) {
            guard let desc = AXHelpers.getDescription(slider)?.lowercased(),
                  let value = extractSliderValue(slider) else { continue }
            if desc == "tempo" {
                state.tempo = value
            } else if positionFieldOrder.contains(desc) || timeFieldOrder.contains(desc) {
                positionFields[desc] = Int(value)
            }
        }
        state.position = join(positionFields, order: positionFieldOrder, separator: ".")
        state.timePosition = join(positionFields, order: timeFieldOrder, separator: ":")

        state.lastUpdated = Date()
        return state
    }

    private static let positionFieldOrder = ["bar", "beat", "division", "tick"]
    private static let timeFieldOrder = ["hours", "minutes", "seconds", "frames"]

    /// Assemble the readable fields in `order` into a display string, or nil if the
    /// leading field is absent (i.e. the ruler isn't showing this format at all).
    private static func join(
        _ fields: [String: Int], order: [String], separator: String
    ) -> String? {
        guard let first = order.first, fields[first] != nil else { return nil }
        let values = order.compactMap { fields[$0] }
        return values.map(String.init).joined(separator: separator)
    }

    // MARK: - Private helpers

    private static func extractTrackName(from header: AXUIElement) -> String {
        // Logic 12.x: the name lives in the AXTextField's description (and value).
        if let field = AXHelpers.findDescendant(of: header, role: kAXTextFieldRole, maxDepth: 4) {
            if let desc = AXHelpers.getDescription(field), !desc.isEmpty, desc != "name" {
                return desc
            }
            if let value = extractTextValue(field), !value.isEmpty {
                return value
            }
        }
        // Fallback: parse the layout item's own description: Track N “NAME”
        if let parsed = parseNameFromLayoutDescription(AXHelpers.getDescription(header)) {
            return parsed
        }
        if let text = AXHelpers.findDescendant(of: header, role: kAXStaticTextRole, maxDepth: 3),
           let name = extractTextValue(text), !name.isEmpty {
            return name
        }
        return AXHelpers.getTitle(header) ?? "Untitled"
    }

    /// Parse a name out of an AXLayoutItem description formatted as: Track N “NAME”
    private static func parseNameFromLayoutDescription(_ desc: String?) -> String? {
        guard let desc else { return nil }
        if let open = desc.firstIndex(of: "\u{201C}"),  // “
           let close = desc.lastIndex(of: "\u{201D}"),   // ”
           open < close {
            return String(desc[desc.index(after: open)..<close])
        }
        return nil
    }

    /// Read a checkbox state by its AXDescription within a track header.
    private static func extractCheckboxByDescription(from header: AXUIElement, description: String) -> Bool? {
        let boxes = AXHelpers.findAllDescendants(of: header, role: kAXCheckBoxRole, maxDepth: 4)
        guard let box = boxes.first(where: { AXHelpers.getDescription($0) == description }) else {
            return nil
        }
        return extractCheckboxState(box)
    }

    /// Read the "Has Focus" radio-button state used by Logic to mark the selected track.
    private static func extractTrackFocusState(from header: AXUIElement) -> Bool {
        let radios = AXHelpers.findAllDescendants(of: header, role: kAXRadioButtonRole, maxDepth: 4)
        guard let focus = radios.first(where: { AXHelpers.getDescription($0) == "Has Focus" }) else {
            return false
        }
        return extractCheckboxState(focus) ?? false
    }

    /// Read the volume (and pan, if present) sliders from a track header.
    /// Volume slider is described "Volume"; the pan slider is the remaining slider.
    ///
    /// Returns nil for a control that isn't exposed. At small track heights Logic drops
    /// the header sliders from its AX tree entirely; the previous 0.0 default made that
    /// read-back artefact indistinguishable from genuinely silenced tracks.
    private static func extractTrackVolumePan(from header: AXUIElement) -> (Double?, Double?) {
        let sliders = AXHelpers.findAllDescendants(of: header, role: kAXSliderRole, maxDepth: 4)
        let volumeSlider = sliders.first { AXHelpers.getDescription($0) == "Volume" }
        let panSlider = sliders.first { $0 != volumeSlider }
        return (volumeSlider.flatMap { extractSliderValue($0) },
                panSlider.flatMap { extractSliderValue($0) })
    }

    /// Best-effort track type from the row's UI controls.
    ///
    /// The row's own AXDescription is just `Track N “NAME”` and carries no type at all —
    /// matching against it (as this used to) could only ever produce `unknown`, or worse,
    /// a type guessed from words in the user's track name. So we look at the *controls*
    /// inside the row, whose descriptions are UI labels, and skip anything containing the
    /// track name so a track called "Drummer Idee" can't masquerade as a Drummer track.
    ///
    /// Deliberately conservative: an unrecognised row stays `unknown` rather than being
    /// assigned a plausible-looking wrong type.
    private static func inferTrackType(from header: AXUIElement, name: String) -> TrackType {
        // A Folder/Summing Stack master is the one row with a disclosure triangle.
        if AXHelpers.findDescendant(of: header, role: kAXDisclosureTriangleRole, maxDepth: 4) != nil {
            return .trackStack
        }

        let controlRoles: Set<String> = [
            kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXImageRole,
            kAXPopUpButtonRole, kAXMenuButtonRole,
        ]
        let needle = name.lowercased()
        let labels = AXHelpers.findAllDescendants(of: header, maxDepth: 4)
            .filter { controlRoles.contains(AXHelpers.getRole($0) ?? "") }
            .compactMap { AXHelpers.getDescription($0) ?? AXHelpers.getTitle($0) }
            .map { $0.lowercased() }
            .filter { label in needle.isEmpty || !label.contains(needle) }
            .joined(separator: " ")

        if labels.contains("drummer") { return .drummer }
        if labels.contains("software instrument") { return .softwareInstrument }
        if labels.contains("external midi") { return .externalMIDI }
        if labels.contains("audio track") || labels.contains("input monitoring") { return .audio }
        if labels.contains("aux") { return .aux }
        if labels.contains("stereo out") || labels.contains("master") { return .master }
        return .unknown
    }

    private static func extractTrackColor(from header: AXUIElement) -> String? {
        // Logic Pro may expose color via a custom attribute or the element's description
        let desc = AXHelpers.getDescription(header) ?? ""
        if desc.lowercased().contains("color") {
            return desc
        }
        return nil
    }
}
