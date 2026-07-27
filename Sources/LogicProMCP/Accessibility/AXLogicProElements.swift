import ApplicationServices
import Foundation

/// Logic Pro-specific AX element finders.
/// Navigates from the app root to known UI regions using role/title/structure heuristics.
/// Logic Pro's AX tree structure may change between versions; these are best-effort.
enum AXLogicProElements {
    /// Get the root AX element for Logic Pro. Returns nil if not running.
    static func appRoot() -> AXUIElement? {
        guard let pid = ProcessUtils.logicProPID() else { return nil }
        return AXHelpers.axApp(pid: pid)
    }

    /// Get the main window element.
    static func mainWindow() -> AXUIElement? {
        guard let app = appRoot() else { return nil }
        return AXHelpers.getAttribute(app, kAXMainWindowAttribute)
    }

    // MARK: - Transport

    /// Find the transport bar area (toolbar/group containing play, stop, record, etc.)
    static func getTransportBar() -> AXUIElement? {
        guard let window = mainWindow() else { return nil }
        // Logic Pro's transport is typically an AXToolbar or AXGroup near the top
        if let toolbar = AXHelpers.findChild(of: window, role: kAXToolbarRole) {
            return toolbar
        }
        // Fallback: search for a group containing transport-like buttons
        return AXHelpers.findDescendant(of: window, role: kAXGroupRole, identifier: "Transport")
    }

    /// Find a specific transport button by its title or description.
    static func findTransportButton(named name: String) -> AXUIElement? {
        guard let transport = getTransportBar() else { return nil }
        // Try by title first
        if let button = AXHelpers.findDescendant(of: transport, role: kAXButtonRole, title: name) {
            return button
        }
        // Try by description (some buttons use AXDescription instead of AXTitle)
        let buttons = AXHelpers.findAllDescendants(of: transport, role: kAXButtonRole, maxDepth: 4)
        for button in buttons {
            if AXHelpers.getDescription(button) == name {
                return button
            }
        }
        return nil
    }

    // MARK: - Tracks

    /// Find the track header area containing individual track rows.
    /// In Logic Pro 12.x the arrange track headers live in an AXGroup whose
    /// description is "Tracks header"; its children are one AXLayoutItem per track.
    static func getTrackHeaders() -> AXUIElement? {
        guard let window = mainWindow() else { return nil }
        // Logic Pro 12.x: the track header column is an AXGroup described "Tracks header".
        if let area = AXHelpers.findDescendant(of: window, role: kAXGroupRole, description: "Tracks header", maxDepth: 14) {
            return area
        }
        // Legacy / version fallbacks (older layouts).
        if let area = AXHelpers.findDescendant(of: window, role: kAXListRole, identifier: "Track Headers") {
            return area
        }
        if let area = AXHelpers.findDescendant(of: window, role: kAXScrollAreaRole, identifier: "Tracks") {
            return area
        }
        return AXHelpers.findDescendant(of: window, role: kAXOutlineRole, maxDepth: 5)
    }

    /// Track row elements within the header area (one AXLayoutItem per track).
    private static func trackRows(in headers: AXUIElement) -> [AXUIElement] {
        let children = AXHelpers.getChildren(headers)
        let layoutItems = children.filter { AXHelpers.getRole($0) == kAXLayoutItemRole }
        // Some layouts wrap rows directly; fall back to all children if no layout items.
        return layoutItems.isEmpty ? children : layoutItems
    }

    /// Find a track header at a specific index (0-based).
    static func findTrackHeader(at index: Int) -> AXUIElement? {
        guard let headers = getTrackHeaders() else { return nil }
        let rows = trackRows(in: headers)
        guard index >= 0 && index < rows.count else { return nil }
        return rows[index]
    }

    /// Enumerate all track header rows.
    static func allTrackHeaders() -> [AXUIElement] {
        guard let headers = getTrackHeaders() else { return [] }
        return trackRows(in: headers)
    }

    /// The rect in which track header rows are actually *visible* on screen.
    ///
    /// IMPORTANT: the frame of the `AXGroup desc="Tracks header"` element is the whole
    /// scrollable content (observed live: 1924 px tall for 47 tracks, spanning far above
    /// and below the window), so it must never be used for visibility tests — every row
    /// would look visible. The enclosing AXScrollArea reports the real viewport; when it
    /// cannot be found we fall back to the main window minus the toolbar/ruler strip at
    /// the top and the horizontal scroller at the bottom (measured on Logic 12.3).
    static func trackHeadersViewport() -> CGRect? {
        guard let window = mainWindow(), let windowFrame = AXHelpers.elementFrame(window) else {
            return nil
        }

        if let headers = getTrackHeaders(),
           let scrollFrame = enclosingScrollAreaFrame(of: headers, within: windowFrame) {
            return scrollFrame
        }

        // Fallback: toolbar + ruler occupy roughly the top 120 px of the window, the
        // horizontal scroller the bottom ~12 px.
        let inset = windowFrame.divided(atDistance: 120, from: .minYEdge).remainder
        let viewport = inset.divided(atDistance: 12, from: .maxYEdge).remainder
        return viewport.height >= 60 ? viewport : nil
    }

    /// Walk up from `element` looking for an AXScrollArea whose frame is a plausible
    /// viewport: inside the window and clearly smaller than the scroll content.
    private static func enclosingScrollAreaFrame(
        of element: AXUIElement, within windowFrame: CGRect
    ) -> CGRect? {
        var current: AXUIElement? = element
        for _ in 0..<8 {
            guard let node = current else { return nil }
            if AXHelpers.getRole(node) == kAXScrollAreaRole,
               let frame = AXHelpers.elementFrame(node),
               frame.height >= 60,
               windowFrame.insetBy(dx: -2, dy: -2).contains(frame) {
                return frame
            }
            current = AXHelpers.getAttribute(node, kAXParentAttribute)
        }
        return nil
    }

    /// Frame of the track header row at `index`, or nil if the row does not exist.
    static func trackRowFrame(at index: Int) -> CGRect? {
        guard let row = findTrackHeader(at: index) else { return nil }
        return AXHelpers.elementFrame(row)
    }

    // MARK: - Mixer

    /// Find the mixer area.
    static func getMixerArea() -> AXUIElement? {
        guard let window = mainWindow() else { return nil }
        // The mixer typically appears as a distinct group/scroll area
        if let mixer = AXHelpers.findDescendant(of: window, role: kAXGroupRole, identifier: "Mixer") {
            return mixer
        }
        return AXHelpers.findDescendant(of: window, role: kAXScrollAreaRole, identifier: "Mixer")
    }

    /// Find a volume fader for a specific track index within the mixer.
    static func findFader(trackIndex: Int) -> AXUIElement? {
        guard let mixer = getMixerArea() else { return nil }
        let strips = AXHelpers.getChildren(mixer)
        guard trackIndex >= 0 && trackIndex < strips.count else { return nil }
        let strip = strips[trackIndex]
        // Fader is an AXSlider within the channel strip
        return AXHelpers.findDescendant(of: strip, role: kAXSliderRole, maxDepth: 4)
    }

    /// Find the pan knob for a track in the mixer.
    static func findPanKnob(trackIndex: Int) -> AXUIElement? {
        guard let mixer = getMixerArea() else { return nil }
        let strips = AXHelpers.getChildren(mixer)
        guard trackIndex >= 0 && trackIndex < strips.count else { return nil }
        let strip = strips[trackIndex]
        // Pan is typically the second slider or a knob-type element
        let sliders = AXHelpers.findAllDescendants(of: strip, role: kAXSliderRole, maxDepth: 4)
        // Convention: first slider = volume, second = pan (if present)
        return sliders.count > 1 ? sliders[1] : nil
    }

    // MARK: - Menu Bar

    /// Get the menu bar for Logic Pro.
    static func getMenuBar() -> AXUIElement? {
        guard let app = appRoot() else { return nil }
        return AXHelpers.getAttribute(app, kAXMenuBarAttribute)
    }

    /// Navigate menu: e.g. menuItem(path: ["File", "New..."]).
    static func menuItem(path: [String]) -> AXUIElement? {
        guard var current = getMenuBar() else { return nil }
        for title in path {
            let children = AXHelpers.getChildren(current)
            var found = false
            for child in children {
                // Menu bar items and menu items both use AXTitle
                if AXHelpers.getTitle(child) == title {
                    current = child
                    found = true
                    break
                }
                // Check child menu items inside a menu
                let subChildren = AXHelpers.getChildren(child)
                for sub in subChildren {
                    if AXHelpers.getTitle(sub) == title {
                        current = sub
                        found = true
                        break
                    }
                }
                if found { break }
            }
            if !found { return nil }
        }
        return current
    }

    /// Find a menu item whose title contains every fragment in `fragments`
    /// (case-insensitive), searching the whole menu bar including submenus.
    /// Returns nil when the menus haven't been populated yet.
    static func findMenuItem(fragments: [String]) -> AXUIElement? {
        guard let menuBar = getMenuBar(), !fragments.isEmpty else { return nil }
        return searchMenu(menuBar, fragments: fragments, depth: 6)
    }

    private static func searchMenu(
        _ element: AXUIElement, fragments: [String], depth: Int
    ) -> AXUIElement? {
        guard depth > 0 else { return nil }
        for child in AXHelpers.getChildren(element) {
            if AXHelpers.getRole(child) == kAXMenuItemRole {
                let title = AXHelpers.getTitle(child) ?? ""
                if fragments.allSatisfy({ title.localizedCaseInsensitiveContains($0) }) {
                    return child
                }
            }
            if let found = searchMenu(child, fragments: fragments, depth: depth - 1) {
                return found
            }
        }
        return nil
    }

    /// Whether a menu item / control is currently enabled.
    ///
    /// Essential before pressing a menu item: `AXUIElementPerformAction(…, kAXPressAction)`
    /// returns `.success` on a *disabled* item as well, so the press looks like it worked
    /// while nothing happened. Logic disables its "New … Track" items depending on where
    /// the focus is, and acting on that false success previously led to work being done
    /// against track indices that never existed.
    static func isEnabled(_ element: AXUIElement) -> Bool {
        guard let enabled: Bool = AXHelpers.getAttribute(element, kAXEnabledAttribute) else {
            return true  // attribute absent → assume usable
        }
        return enabled
    }

    /// Locate the "Create Track Stack…" command anywhere in the menu bar.
    /// Language-tolerant: matches any menu item whose title contains "Stack"
    /// (kept verbatim in localized builds, e.g. German "Track-Stack erstellen…"),
    /// preferring one that also reads as a *create* action. Returns nil if the
    /// menus haven't been populated yet — the caller should fall back to the
    /// ⌘⇧D shortcut in that case.
    static func findCreateTrackStackMenuItem() -> AXUIElement? {
        guard let menuBar = getMenuBar() else { return nil }
        var fallback: AXUIElement?
        for top in AXHelpers.getChildren(menuBar) {
            for submenu in AXHelpers.getChildren(top) {
                for item in AXHelpers.getChildren(submenu) {
                    let title = AXHelpers.getTitle(item) ?? ""
                    guard title.localizedCaseInsensitiveContains("Stack") else { continue }
                    if title.localizedCaseInsensitiveContains("Create")
                        || title.localizedCaseInsensitiveContains("erstell") {
                        return item
                    }
                    if fallback == nil { fallback = item }
                }
            }
        }
        return fallback
    }

    /// Find the modal sheet currently attached to the main window (e.g. the
    /// Track Stack type chooser). Returns nil when no sheet is present — never
    /// falls back to the window itself, so descendant searches can't stray into
    /// the arrange area (whose track rows also expose AXRadioButtons).
    static func frontSheet() -> AXUIElement? {
        guard let window = mainWindow() else { return nil }
        if let sheet = AXHelpers.findChild(of: window, role: kAXSheetRole) {
            return sheet
        }
        return AXHelpers.findDescendant(of: window, role: kAXSheetRole, maxDepth: 4)
    }

    // MARK: - Arrangement

    /// Find the main arrangement area (the timeline/tracks view).
    static func getArrangementArea() -> AXUIElement? {
        guard let window = mainWindow() else { return nil }
        if let area = AXHelpers.findDescendant(of: window, role: kAXGroupRole, identifier: "Arrangement") {
            return area
        }
        return AXHelpers.findDescendant(of: window, role: kAXScrollAreaRole, identifier: "Arrangement")
    }

    // MARK: - Track Controls

    /// Find the mute control (AXCheckBox "Mute") on a track header.
    static func findTrackMuteButton(trackIndex: Int) -> AXUIElement? {
        guard let header = findTrackHeader(at: trackIndex) else { return nil }
        return findControlByDescription(in: header, role: kAXCheckBoxRole, description: "Mute")
            ?? findButtonByDescriptionPrefix(in: header, prefix: "Mute")
    }

    /// Find the solo control (AXCheckBox "Solo") on a track header.
    static func findTrackSoloButton(trackIndex: Int) -> AXUIElement? {
        guard let header = findTrackHeader(at: trackIndex) else { return nil }
        return findControlByDescription(in: header, role: kAXCheckBoxRole, description: "Solo")
            ?? findButtonByDescriptionPrefix(in: header, prefix: "Solo")
    }

    /// Find the record-arm control (AXCheckBox "Record Enable") on a track header.
    static func findTrackArmButton(trackIndex: Int) -> AXUIElement? {
        guard let header = findTrackHeader(at: trackIndex) else { return nil }
        return findControlByDescription(in: header, role: kAXCheckBoxRole, description: "Record Enable")
            ?? findButtonByDescriptionPrefix(in: header, prefix: "Record")
    }

    /// Find the "Has Focus" selection control (AXRadioButton) on a track header.
    static func findTrackFocusButton(trackIndex: Int) -> AXUIElement? {
        guard let header = findTrackHeader(at: trackIndex) else { return nil }
        return findControlByDescription(in: header, role: kAXRadioButtonRole, description: "Has Focus")
    }

    /// Find the track name text field on a header.
    static func findTrackNameField(trackIndex: Int) -> AXUIElement? {
        guard let header = findTrackHeader(at: trackIndex) else { return nil }
        return AXHelpers.findDescendant(of: header, role: kAXTextFieldRole, maxDepth: 4)
            ?? AXHelpers.findDescendant(of: header, role: kAXStaticTextRole, maxDepth: 4)
    }

    // MARK: - Helpers

    /// Find a descendant control of a given role whose AXDescription matches exactly.
    static func findControlByDescription(
        in element: AXUIElement, role: String, description: String
    ) -> AXUIElement? {
        let controls = AXHelpers.findAllDescendants(of: element, role: role, maxDepth: 4)
        return controls.first { AXHelpers.getDescription($0) == description }
    }

    private static func findButtonByDescriptionPrefix(
        in element: AXUIElement, prefix: String
    ) -> AXUIElement? {
        let buttons = AXHelpers.findAllDescendants(of: element, role: kAXButtonRole, maxDepth: 4)
        return buttons.first { button in
            guard let desc = AXHelpers.getDescription(button) else { return false }
            return desc.hasPrefix(prefix)
        }
    }
}
