/// What a press of Escape means, given only what is on screen.
///
/// Modelled as a value rather than handled inline in the key monitor for the same
/// reason ``SelectionGesture`` is: a decision buried in an AppKit event closure can
/// only be checked by a human with a keyboard, and this one is reachable from four
/// different UI states that a human tester will not think to enumerate.
public enum EscapeAction: Sendable, Hashable {
    /// Throw away the frame the user is mid-way through drawing; the selection that
    /// was live before the drag is untouched.
    case cancelDrag
    /// Close the open composer or pin editor, discarding its draft.
    case dismissCard
    /// Leave annotate mode entirely.
    case exitAnnotateMode
    /// AnnotKit has no claim on this keystroke; the host must see it.
    case passThrough

    /// Whether the key monitor should SWALLOW the event.
    ///
    /// This is the monitor's whole contract with the host, and getting it wrong is
    /// not cosmetic: AnnotKit runs IN-PROCESS with its host, so an Escape it acts on
    /// and also forwards is delivered twice — the overlay leaves annotate mode while
    /// the host closes its own sheet, from one press. Only ``passThrough`` (where
    /// AnnotKit deliberately did nothing) may forward.
    public var consumesEvent: Bool { self != .passThrough }
}

/// The pure Escape decision: given the three pieces of overlay state that a press
/// of Escape can plausibly refer to, name the ONE thing it backs out of.
///
/// The design is "undo one level at a time", and the ordering below is that policy.
/// A first Escape that exited annotate mode outright would take a half-typed comment
/// with it — the single irreversible thing in the flow, since a dismissed mode can be
/// re-entered with one click but a discarded draft cannot be retyped from anywhere.
public enum EscapeRule {
    /// Resolve a press of Escape. Precedence is strict and the order is the whole
    /// rule:
    ///
    /// 1. **Not annotating → ``EscapeAction/passThrough``.** AnnotKit is not active,
    ///    so the host's own Escape handling — closing ITS sheets, dismissing ITS
    ///    menus — must be exactly as it was before AnnotKit was installed. An
    ///    overlay that ate Escape while idle would break the host app permanently
    ///    and look like the host's bug.
    /// 2. **Drawing a frame → ``EscapeAction/cancelDrag``.** The in-flight gesture is
    ///    the most immediate thing on screen. Tested BEFORE the card rather than
    ///    after because the two genuinely COEXIST: the catcher stays live behind an
    ///    open composer, so a user can begin drawing a new frame while the previous
    ///    note's composer is still up. Card-first would then discard the draft the
    ///    user never touched and leave the band they are actively dragging on screen.
    /// 3. **An open card → ``EscapeAction/dismissCard``.**
    /// 4. **Otherwise → ``EscapeAction/exitAnnotateMode``.**
    public static func resolve(isAnnotating: Bool, isDrawingFrame: Bool, hasOpenCard: Bool) -> EscapeAction {
        guard isAnnotating else { return .passThrough }
        if isDrawingFrame { return .cancelDrag }
        if hasOpenCard { return .dismissCard }
        return .exitAnnotateMode
    }
}
