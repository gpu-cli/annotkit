import Foundation
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// Copies notes to the system pasteboard as markdown or JSON. The zero-config
/// fallback sink: paste the structured output straight into an agent prompt.
public struct ClipboardSink: AnnotationSink {
    public let format: OutputFormat

    public init(format: OutputFormat = .markdown) {
        self.format = format
    }

    /// Render notes in the configured format (exposed for testing without
    /// touching the pasteboard).
    public func render(_ notes: [AnnotationNote]) throws -> String {
        switch format {
        case .markdown: return AnnotationFormatter.markdown(notes)
        case .json: return try AnnotationFormatter.json(notes)
        }
    }

    public func flush(_ notes: [AnnotationNote]) throws {
        let text = try render(notes)
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = text
        #endif
    }
}
