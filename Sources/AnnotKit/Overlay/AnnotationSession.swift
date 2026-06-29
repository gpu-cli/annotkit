import Combine
import CoreGraphics
import Foundation

/// The platform-independent heart of the overlay: tracks annotate mode, the
/// hovered and selected elements, and the list of pending notes, and turns a
/// selected element plus a comment into an ``AnnotationNote`` that it flushes to
/// the sink. The macOS/iOS overlay hosts drive this; it owns no UI, so it is
/// unit-testable without a window.
@MainActor
public final class AnnotationSession: ObservableObject {
    public enum Mode: Sendable {
        case idle
        case annotating
    }

    @Published public private(set) var mode: Mode = .idle
    @Published public private(set) var pending: [AnnotationNote] = []
    @Published public private(set) var hovered: Element?
    @Published public private(set) var selected: Element?

    private let source: ElementSource
    private let sink: AnnotationSink
    private let route: () -> String?
    private let timestamp: () -> String
    private let makeID: () -> String

    /// Hover throttle. The hit-test is a cheap cross-process point query, but
    /// `onContinuousHover` fires very frequently, so cap it at ~60fps to keep the
    /// main thread responsive. Lives here so both platform hosts benefit.
    private var lastHover = Date.distantPast
    private let hoverInterval: TimeInterval = 1.0 / 60.0

    public init(
        source: ElementSource,
        sink: AnnotationSink,
        route: @escaping () -> String? = { nil },
        timestamp: @escaping () -> String = { ISO8601DateFormatter().string(from: Date()) },
        makeID: @escaping () -> String = { String(UUID().uuidString.prefix(6)).lowercased() }
    ) {
        self.source = source
        self.sink = sink
        self.route = route
        self.timestamp = timestamp
        self.makeID = makeID
    }

    public func start() { mode = .annotating }

    public func stop() {
        mode = .idle
        hovered = nil
        // Dismiss any open composer so it does not linger (and get clipped by a
        // resized idle overlay) after leaving annotate mode.
        selected = nil
    }

    /// Update the hover highlight for a screen point (AX top-left coordinates).
    /// Throttled to ~60fps so rapid hover events do not flood the point query.
    public func hover(atAXPoint point: CGPoint) {
        guard mode == .annotating else { return }
        let now = Date()
        guard now.timeIntervalSince(lastHover) >= hoverInterval else { return }
        lastHover = now
        hovered = source.hitTest(point)
    }

    /// Select the element under a screen point (AX top-left coordinates).
    @discardableResult
    public func select(atAXPoint point: CGPoint) -> Element? {
        guard mode == .annotating else { return nil }
        selected = source.hitTest(point)
        return selected
    }

    /// Capture a screenshot of the currently selected element, if any.
    public func screenshotSelected() async -> CapturedImage? {
        guard let selected else { return nil }
        return try? await source.screenshot(of: selected)
    }

    /// Turn the selected element plus a comment into a pending note.
    @discardableResult
    public func addNote(
        comment: String,
        selectedText: String? = nil,
        screenshot: CapturedImage? = nil
    ) -> AnnotationNote? {
        guard let element = selected else { return nil }
        let note = AnnotationNote(
            id: makeID(),
            route: route(),
            selector: source.selector(for: element),
            elementPath: element.path.map(\.pathDescription).joined(separator: " > "),
            selectedText: selectedText,
            comment: comment,
            screenshot: screenshot,
            timestamp: timestamp()
        )
        pending.append(note)
        selected = nil
        return note
    }

    /// Flush pending notes to the sink and clear them.
    public func flush() throws {
        try sink.flush(pending)
        pending.removeAll()
    }

    public func clear() {
        pending.removeAll()
        selected = nil
    }

    /// Drop the current selection without capturing a note (composer cancel).
    public func cancelSelection() {
        selected = nil
    }

    /// A short, human label for the selected element (for the composer header).
    public var selectionLabel: String? {
        guard let selected else { return nil }
        if !selected.label.isEmpty { return selected.label }
        return selected.id
    }
}
