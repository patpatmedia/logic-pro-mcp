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
        let trackType = inferTrackType(from: header)
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

    /// Read transport bar elements and build a TransportState.
    static func extractTransportState(from transport: AXUIElement) -> TransportState {
        var state = TransportState()

        // Find and read transport button states
        let buttons = AXHelpers.findAllDescendants(of: transport, role: kAXButtonRole, maxDepth: 4)
        for button in buttons {
            let desc = AXHelpers.getDescription(button) ?? AXHelpers.getTitle(button) ?? ""
            let pressed = extractButtonState(button) ?? false
            let descLower = desc.lowercased()

            if descLower.contains("play") {
                state.isPlaying = pressed
            } else if descLower.contains("record") && !descLower.contains("arm") {
                state.isRecording = pressed
            } else if descLower.contains("cycle") || descLower.contains("loop") {
                state.isCycleEnabled = pressed
            } else if descLower.contains("metronome") || descLower.contains("click") {
                state.isMetronomeEnabled = pressed
            }
        }

        // Find text fields for tempo, position
        let texts = AXHelpers.findAllDescendants(of: transport, role: kAXStaticTextRole, maxDepth: 4)
        for text in texts {
            guard let value = extractTextValue(text) else { continue }
            let desc = AXHelpers.getDescription(text) ?? ""
            let descLower = desc.lowercased()

            if descLower.contains("tempo") || descLower.contains("bpm") {
                if let tempo = Double(value.replacingOccurrences(of: " BPM", with: "")) {
                    state.tempo = tempo
                }
            } else if descLower.contains("position") || value.contains(".") && value.contains(":") == false {
                // Bar.Beat.Division.Tick format
                if value.filter({ $0 == "." }).count >= 2 {
                    state.position = value
                }
            } else if value.contains(":") {
                // Time format HH:MM:SS
                state.timePosition = value
            }
        }

        state.lastUpdated = Date()
        return state
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
    private static func extractTrackVolumePan(from header: AXUIElement) -> (Double, Double) {
        let sliders = AXHelpers.findAllDescendants(of: header, role: kAXSliderRole, maxDepth: 4)
        let volumeSlider = sliders.first { AXHelpers.getDescription($0) == "Volume" }
        let panSlider = sliders.first { $0 != volumeSlider }
        let volume = volumeSlider.flatMap { extractSliderValue($0) } ?? 0.0
        let pan = panSlider.flatMap { extractSliderValue($0) } ?? 0.0
        return (volume, pan)
    }

    private static func inferTrackType(from header: AXUIElement) -> TrackType {
        // Attempt to infer type from icon description or element identifiers
        let desc = AXHelpers.getDescription(header)?.lowercased() ?? ""
        let title = AXHelpers.getTitle(header)?.lowercased() ?? ""
        let combined = desc + " " + title

        if combined.contains("audio") { return .audio }
        if combined.contains("instrument") || combined.contains("software") { return .softwareInstrument }
        if combined.contains("drummer") { return .drummer }
        if combined.contains("external") || combined.contains("midi") { return .externalMIDI }
        if combined.contains("aux") { return .aux }
        if combined.contains("bus") { return .bus }
        if combined.contains("master") || combined.contains("stereo out") { return .master }
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
