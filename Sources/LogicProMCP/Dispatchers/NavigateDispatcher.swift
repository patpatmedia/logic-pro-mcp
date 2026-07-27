import Foundation
import MCP

struct NavigateDispatcher {
    static let tool = Tool(
        name: "logic_navigate",
        description: """
            Navigation and markers in Logic Pro. \
            Commands: goto_bar, goto_marker, create_marker, delete_marker, \
            rename_marker, zoom_to_fit, set_zoom, toggle_view. \
            Params by command: \
            goto_bar -> { bar: Int }; \
            goto_marker -> { index: Int } or { name: String }; \
            create_marker -> { name: String } (at current playhead); \
            rename_marker -> { index: Int, name: String }; \
            delete_marker -> { index: Int }; \
            set_zoom -> { level: String ("in"|"out"|"fit"), axis: String \
            ("horizontal" (default)|"vertical"), steps: Int (1-10, default 1) } — \
            vertical zoom changes the track row height and is verified; it needs the \
            keyboard focus in the arrange area; \
            toggle_view -> { view: String } ("mixer", "piano_roll", "score", \
            "step_editor", "library", "inspector", "automation")
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "description": .string("Navigation command to execute"),
                ]),
                "params": .object([
                    "type": .string("object"),
                    "description": .string("Command-specific parameters"),
                ]),
            ]),
            "required": .array([.string("command")]),
        ])
    )

    static func handle(
        command: String,
        params: [String: Value],
        router: ChannelRouter,
        cache: StateCache
    ) async -> CallTool.Result {
        switch command {
        case "goto_bar":
            let bar = params["bar"]?.intValue ?? 1
            let result = await router.route(
                operation: "nav.goto_bar",
                params: ["bar": String(bar)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "goto_marker":
            if let index = params["index"]?.intValue {
                let result = await router.route(
                    operation: "nav.goto_marker",
                    params: ["index": String(index)]
                )
                return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)
            }
            if let name = params["name"]?.stringValue {
                let markers = await cache.getMarkers()
                if let marker = markers.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
                    let result = await router.route(
                        operation: "nav.goto_marker",
                        params: ["index": String(marker.id)]
                    )
                    return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)
                }
                return CallTool.Result(content: [.text("No marker found matching '\(name)'")], isError: true)
            }
            return CallTool.Result(content: [.text("goto_marker requires 'index' or 'name' param")], isError: true)

        case "create_marker":
            let name = params["name"]?.stringValue ?? "Marker"
            let result = await router.route(
                operation: "nav.create_marker",
                params: ["name": name]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "delete_marker":
            let index = params["index"]?.intValue ?? 0
            let result = await router.route(
                operation: "nav.delete_marker",
                params: ["index": String(index)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "rename_marker":
            let index = params["index"]?.intValue ?? 0
            let name = params["name"]?.stringValue ?? ""
            let result = await router.route(
                operation: "nav.rename_marker",
                params: ["index": String(index), "name": name]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "zoom_to_fit":
            let result = await router.route(operation: "nav.zoom_to_fit")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "set_zoom":
            // Logic has no "set an absolute zoom level" command — only stepwise zoom key
            // commands. The old numeric `level` parameter mapped to nothing at all and
            // always failed with "No keyboard shortcut mapped for: nav.set_zoom_level".
            let level = params["level"]?.stringValue ?? "fit"
            let axis = params["axis"]?.stringValue ?? "horizontal"
            let steps = max(1, min(10, params["steps"]?.intValue ?? 1))

            if level == "fit" {
                let result = await router.route(operation: "nav.zoom_to_fit")
                return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)
            }
            guard level == "in" || level == "out" else {
                return CallTool.Result(
                    content: [.text("Unknown zoom level: \(level). Use \"in\", \"out\" or \"fit\".")],
                    isError: true
                )
            }
            guard axis == "horizontal" || axis == "vertical" else {
                return CallTool.Result(
                    content: [.text("Unknown zoom axis: \(axis). Use \"horizontal\" or \"vertical\".")],
                    isError: true
                )
            }
            let operation = "nav.zoom_\(level == "in" ? "in" : "out")"
                + (axis == "vertical" ? "_vertical" : "")

            var lastResult = await router.route(operation: operation)
            for _ in 1..<steps where lastResult.isSuccess {
                lastResult = await router.route(operation: operation)
            }
            return CallTool.Result(content: [.text(lastResult.message)], isError: !lastResult.isSuccess)

        case "toggle_view":
            let view = params["view"]?.stringValue ?? "mixer"
            let operation: String
            switch view {
            case "mixer": operation = "view.toggle_mixer"
            case "piano_roll": operation = "view.toggle_piano_roll"
            case "score": operation = "view.toggle_score_editor"
            case "step_editor": operation = "view.toggle_step_editor"
            case "library": operation = "view.toggle_library"
            case "inspector": operation = "view.toggle_inspector"
            case "automation": operation = "automation.toggle_view"
            default:
                return CallTool.Result(
                    content: [.text("Unknown view: \(view). Available: mixer, piano_roll, score, step_editor, library, inspector, automation")],
                    isError: true
                )
            }
            let result = await router.route(operation: operation)
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        default:
            return CallTool.Result(
                content: [.text("Unknown navigate command: \(command). Available: goto_bar, goto_marker, create_marker, delete_marker, rename_marker, zoom_to_fit, set_zoom, toggle_view")],
                isError: true
            )
        }
    }
}
