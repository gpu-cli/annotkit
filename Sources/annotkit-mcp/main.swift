import AnnotKitMCP
import Foundation

// Thin stdio MCP server: read one JSON-RPC request per line, dispatch, and write
// the response line. The note store path comes from the first argument or
// ANNOTKIT_NOTES, defaulting to AGENTATION_NOTES.json (written by JSONFileSink).
let path = CommandLine.arguments.dropFirst().first
    ?? ProcessInfo.processInfo.environment["ANNOTKIT_NOTES"]
    ?? "AGENTATION_NOTES.json"

let dispatcher = MCPDispatcher(provider: FileNotesStore(path: path))

while let line = readLine(strippingNewline: true) {
    if line.isEmpty { continue }
    if let response = dispatcher.handle(line) {
        print(response)
    }
}
