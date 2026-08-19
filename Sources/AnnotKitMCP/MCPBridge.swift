import AnnotKit
import Foundation

/// Read/resolve access to the captured annotations, so the dispatcher can be
/// tested against an in-memory provider.
public protocol NoteProvider {
    func pending() throws -> [AnnotationNote]
    func resolve(id: String) throws
}

/// JSON-file-backed provider, reading the store written by `JSONFileSink`.
public struct FileNotesStore: NoteProvider {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    public func pending() throws -> [AnnotationNote] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        return (try? JSONDecoder().decode([AnnotationNote].self, from: data)) ?? []
    }

    public func resolve(id: String) throws {
        var notes = try pending()
        notes.removeAll { $0.id == id }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(notes).write(to: URL(fileURLWithPath: path))
    }
}

/// A minimal, clean-room JSON-RPC 2.0 dispatcher implementing the MCP methods an
/// agent needs to consume annotations: `initialize`, `tools/list`, and
/// `tools/call` for `annotation_get_pending` and `annotation_resolve`. Pure and
/// synchronous (no UI, no actor isolation), so it is unit-testable line by line.
public struct MCPDispatcher {
    private let provider: NoteProvider

    public init(provider: NoteProvider) {
        self.provider = provider
    }

    /// Handle one JSON-RPC request line. Returns the response line, or nil for
    /// notifications (which take no response).
    public func handle(_ line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "parse error"]])
        }

        let id = object["id"] ?? NSNull()
        guard let method = object["method"] as? String else {
            return error(id, -32600, "invalid request")
        }

        switch method {
        case "initialize":
            return result(id, [
                "protocolVersion": "2024-11-05",
                "serverInfo": ["name": "annotkit-mcp", "version": "0.1.0"],
                "capabilities": ["tools": [String: Any]()]
            ])
        case "notifications/initialized":
            return nil
        case "tools/list":
            return result(id, ["tools": Self.toolDefinitions()])
        case "tools/call":
            let params = object["params"] as? [String: Any] ?? [:]
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            return handleTool(id, name: name, args: args)
        default:
            return error(id, -32601, "method not found: \(method)")
        }
    }

    private func handleTool(_ id: Any, name: String, args: [String: Any]) -> String? {
        do {
            switch name {
            case "annotation_get_pending":
                let notes = try provider.pending()
                let text = notes.isEmpty
                    ? "No pending annotations."
                    : notes.map(Self.describe).joined(separator: "\n\n")
                return toolResult(id, text)
            case "annotation_resolve":
                guard let noteID = args["id"] as? String else {
                    return error(id, -32602, "missing argument: id")
                }
                try provider.resolve(id: noteID)
                return toolResult(id, "Resolved \(noteID).")
            default:
                return error(id, -32602, "unknown tool: \(name)")
            }
        } catch {
            return self.error(id, -32603, "internal error: \(error)")
        }
    }

    static func toolDefinitions() -> [[String: Any]] {
        [
            [
                "name": "annotation_get_pending",
                "description": "List pending UI annotations (selector, element path, comment, and the host world context each was captured in).",
                "inputSchema": ["type": "object", "properties": [String: Any]()]
            ],
            [
                "name": "annotation_resolve",
                "description": "Mark an annotation resolved by id.",
                "inputSchema": ["type": "object", "properties": ["id": ["type": "string"]], "required": ["id"]]
            ]
        ]
    }

    /// One line per note, plus a second line for the world it was captured in.
    ///
    /// The context goes on its OWN line rather than into the first one: an agent
    /// reading this decides two separate things — which view to change, and which
    /// world to relaunch to see it — and a single line that ran them together made
    /// the note's actual text the hardest part to find.
    static func describe(_ note: AnnotationNote) -> String {
        var line = "[\(note.id)] \(note.selector) (\(note.elementPath)): \(note.comment)"
        if let context = note.context, !context.isEmpty {
            let pairs = context.keys.sorted().map { "\($0)=\(context[$0]!)" }.joined(separator: " ")
            line += "\n    context: \(pairs)"
        }
        return line
    }

    private func result(_ id: Any, _ value: [String: Any]) -> String {
        encode(["jsonrpc": "2.0", "id": id, "result": value])
    }

    private func toolResult(_ id: Any, _ text: String) -> String {
        result(id, ["content": [["type": "text", "text": text]]])
    }

    private func error(_ id: Any, _ code: Int, _ message: String) -> String {
        encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
