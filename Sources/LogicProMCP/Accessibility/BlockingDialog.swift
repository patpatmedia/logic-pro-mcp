import ApplicationServices
import Foundation

/// Detects a modal Logic Pro dialog that is holding the keyboard focus.
///
/// While such an alert is open (e.g. "Do you want to use the audio device …?"), Logic
/// processes NO key command and no click in the arrange area — every synthetic input
/// silently does nothing. Without this check the failure surfaces as a misleading
/// low-level error ("could not confirm rename edit mode (focused role: AXButton)") that
/// points at the wrong code. So every command that synthesizes input checks here first
/// and aborts with the dialog's own text.
///
/// This only ever *reports*. It never dismisses a dialog: these alerts concern the
/// user's audio setup or unsaved work, and answering them is not ours to do.
enum BlockingDialog {
    /// Prefix of every message produced here. The router matches on it to stop walking
    /// the fallback chain — a blocked app blocks every channel, so retrying elsewhere
    /// only produces a second useless error.
    static let messagePrefix = "Logic Pro is showing a modal dialog"

    /// A ready-to-return error message if a modal dialog currently owns the focus,
    /// else nil.
    static func blockingMessage() -> String? {
        guard let dialog = focusedModal() else { return nil }
        let text = dialogText(dialog)
        let quoted = text.map { ": \"\($0)\"" } ?? ""
        return "\(messagePrefix)\(quoted). Keyboard commands and clicks are not processed "
            + "until it is dismissed — nothing was sent. Please answer the dialog in Logic "
            + "(this server deliberately does not click it, since such alerts concern your "
            + "audio setup or unsaved work)."
    }

    /// The focused window if it is a modal dialog/sheet/alert, else nil.
    private static func focusedModal() -> AXUIElement? {
        guard let app = AXLogicProElements.appRoot() else { return nil }
        guard let focused: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedWindowAttribute)
        else { return nil }

        let role = AXHelpers.getRole(focused)
        let subrole: String? = AXHelpers.getAttribute(focused, kAXSubroleAttribute)
        let description = AXHelpers.getDescription(focused)?.lowercased() ?? ""

        // Observed live: the audio-device alert is an AXWindow with subrole AXDialog and
        // description "alert". Sheets (Save, Track Stack type chooser) block input the
        // same way.
        let isModal = subrole == kAXDialogSubrole
            || subrole == kAXSystemDialogSubrole
            || role == kAXSheetRole
            || description == "alert"
        guard isModal else { return nil }

        // A modal that reports no focused element at all is more likely a stale AX
        // reference than a real dialog; require it to contain something pressable.
        let buttons = AXHelpers.findAllDescendants(of: focused, role: kAXButtonRole, maxDepth: 6)
        guard !buttons.isEmpty else { return nil }
        return focused
    }

    /// The dialog's message: its longest static text, which for Logic's alerts is the
    /// actual question rather than the button labels.
    private static func dialogText(_ dialog: AXUIElement) -> String? {
        let texts = AXHelpers.findAllDescendants(of: dialog, role: kAXStaticTextRole, maxDepth: 6)
            .compactMap { AXValueExtractors.extractTextValue($0) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let longest = texts.max(by: { $0.count < $1.count }) else {
            return AXHelpers.getTitle(dialog)
        }
        return longest.replacingOccurrences(of: "\n", with: " ")
    }
}
