import CoreGraphics
import Foundation
import XCTest
@testable import AnnotKit
@testable import AnnotKitMCP

private final class MemoryProvider: NoteProvider {
    var notes: [AnnotationNote]
    private(set) var resolved: [String] = []
    init(_ notes: [AnnotationNote]) { self.notes = notes }
    func pending() throws -> [AnnotationNote] { notes }
    func resolve(id: String) throws {
        resolved.append(id)
        notes.removeAll { $0.id == id }
    }
}

final class MCPDispatcherTests: XCTestCase {
    private func note(id: String = "n1") -> AnnotationNote {
        AnnotationNote(
            id: id, route: "Settings", selector: "#SaveButton",
            elementPath: "AXWindow > #SaveButton", comment: "low contrast",
            timestamp: "2026-06-29T00:00:00Z"
        )
    }

    func testInitializeReportsServer() {
        let dispatcher = MCPDispatcher(provider: MemoryProvider([]))
        let response = dispatcher.handle(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#)
        XCTAssertNotNil(response)
        XCTAssertTrue(response!.contains("annotkit-mcp"))
        XCTAssertTrue(response!.contains("protocolVersion"))
    }

    func testToolsListAdvertisesTools() {
        let dispatcher = MCPDispatcher(provider: MemoryProvider([]))
        let response = dispatcher.handle(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)!
        XCTAssertTrue(response.contains("annotation_get_pending"))
        XCTAssertTrue(response.contains("annotation_resolve"))
    }

    func testGetPendingReturnsNotes() {
        let dispatcher = MCPDispatcher(provider: MemoryProvider([note()]))
        let response = dispatcher.handle(
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"annotation_get_pending","arguments":{}}}"#
        )!
        XCTAssertTrue(response.contains("#SaveButton"))
        XCTAssertTrue(response.contains("low contrast"))
        XCTAssertTrue(response.contains("\"content\""))
    }

    func testResolveCallsProvider() {
        let provider = MemoryProvider([note(id: "abc")])
        let dispatcher = MCPDispatcher(provider: provider)
        _ = dispatcher.handle(
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"annotation_resolve","arguments":{"id":"abc"}}}"#
        )
        XCTAssertEqual(provider.resolved, ["abc"])
    }

    func testNotificationGetsNoResponse() {
        let dispatcher = MCPDispatcher(provider: MemoryProvider([]))
        XCTAssertNil(dispatcher.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
    }

    func testUnknownMethodErrors() {
        let dispatcher = MCPDispatcher(provider: MemoryProvider([]))
        let response = dispatcher.handle(#"{"jsonrpc":"2.0","id":5,"method":"bogus"}"#)!
        XCTAssertTrue(response.contains("-32601"))
    }

    func testJSONFileSinkAndStoreRoundTrip() throws {
        let path = NSTemporaryDirectory() + "annotkit-mcp-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try JSONFileSink(path: path).flush([note(id: "store1")])
        let store = FileNotesStore(path: path)
        XCTAssertEqual(try store.pending().map(\.id), ["store1"])
        try store.resolve(id: "store1")
        XCTAssertTrue(try store.pending().isEmpty)
    }
}
