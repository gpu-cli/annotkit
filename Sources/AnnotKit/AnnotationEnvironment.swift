import Foundation

/// The launch-time embedding contract: everything a host can decide about an
/// AnnotKit instance FROM ITS ENVIRONMENT ALONE, parsed into one value.
///
/// It exists for hosts that run many isolated instances of the same app at once
/// — an HMR session per branch, a warm gallery host, an inspect window — where
/// the launcher, not the app's source, is the thing that knows which world this
/// process is and where its notes belong. Such a host cannot express that by
/// editing `install()` call sites: there is one binary and N launches. It can
/// express it in the env dict it builds per launch, which is exactly what this
/// reads.
///
/// PURE. It takes the environment as an argument rather than reaching for
/// `ProcessInfo`, so every rule below is unit-testable without mutating the
/// process (which is neither thread-safe nor reversible mid-test).
///
/// Recognized variables:
///
/// | Variable                  | Effect                                                        |
/// |---------------------------|---------------------------------------------------------------|
/// | `ANNOTKIT_ENABLE`         | mount the overlay even in a release build                      |
/// | `ANNOTKIT_DISABLE`        | never mount, whatever the build (wins over `ANNOTKIT_ENABLE`)  |
/// | `ANNOTKIT_NOTES_MD`       | markdown snapshot path (default `AGENTATION_NOTES.md`)         |
/// | `ANNOTKIT_NOTES`          | JSON store path — the file `annotkit-mcp` serves               |
/// | `ANNOTKIT_EVENTS`         | append-only JSONL event stream to make the notes watchable     |
/// | `ANNOTKIT_ROUTE`          | the note's `route` when the host supplies none                 |
/// | `ANNOTKIT_CONTEXT`        | world context as `key=value,key=value`                         |
/// | `ANNOTKIT_CONTEXT_<KEY>`  | one world-context entry, key lowercased (wins over the list)   |
///
/// `ANNOTKIT_NOTES` names the JSON store and not the markdown one because
/// `annotkit-mcp` already reads that variable for exactly that file
/// (`Sources/annotkit-mcp/main.swift`). One variable, one file, both halves of
/// the product pointing at it: a host wires an instance to its agent by setting
/// `ANNOTKIT_NOTES` once and passing the same env to both processes.
public struct AnnotationEnvironment: Sendable, Equatable {
    /// `ANNOTKIT_NOTES_MD`, defaulted. Never nil: the markdown snapshot is the
    /// file the `process-agentation-notes` skill reads, so it is always written.
    public var notesPath: String
    /// `ANNOTKIT_NOTES` — the JSON store, written only when asked for. Opt-in
    /// rather than defaulted so a host that just wants the toolbar does not find
    /// a second file appear in its working directory.
    public var storePath: String?
    /// `ANNOTKIT_EVENTS` — the JSONL event stream. Opt-in for the same reason.
    public var eventsPath: String?
    /// `ANNOTKIT_ROUTE` — a fallback for the note's `route` field.
    public var route: String?
    /// `ANNOTKIT_CONTEXT` / `ANNOTKIT_CONTEXT_<KEY>`, merged.
    public var context: [String: String]
    /// `ANNOTKIT_ENABLE` is present and non-empty.
    public var isExplicitlyEnabled: Bool
    /// `ANNOTKIT_DISABLE` is present and non-empty.
    public var isExplicitlyDisabled: Bool

    /// The default markdown destination, matching what the consuming skill expects.
    public static let defaultNotesPath = "AGENTATION_NOTES.md"

    public init(_ environment: [String: String] = ProcessInfo.processInfo.environment) {
        notesPath = Self.path(environment["ANNOTKIT_NOTES_MD"]) ?? Self.defaultNotesPath
        storePath = Self.path(environment["ANNOTKIT_NOTES"])
        eventsPath = Self.path(environment["ANNOTKIT_EVENTS"])
        route = Self.value(environment["ANNOTKIT_ROUTE"])
        isExplicitlyEnabled = Self.value(environment["ANNOTKIT_ENABLE"]) != nil
        isExplicitlyDisabled = Self.value(environment["ANNOTKIT_DISABLE"]) != nil
        context = Self.context(environment)
    }

    /// Resolve the dev gate. `byDefault` is what the BUILD says (DEBUG on, release
    /// off); the environment overrides it, and DISABLE beats ENABLE so a launcher
    /// that wants a clean recording can suppress the overlay unconditionally
    /// without first auditing what else is in the env it inherited.
    public func isEnabled(byDefault: Bool) -> Bool {
        if isExplicitlyDisabled { return false }
        if isExplicitlyEnabled { return true }
        return byDefault
    }

    /// Merge `context` UNDER a host-registered provider's snapshot: the provider
    /// wins on a shared key.
    ///
    /// The provider is evaluated at capture and the environment was frozen at
    /// launch, so on a key both supply the provider is simply the more recent
    /// measurement — a launcher that declared `appearance=dark` is describing how
    /// it started the app, while a provider reporting `appearance=light` is
    /// describing what the person was actually looking at when they wrote the note.
    /// A host that wants the launcher's value to stand simply does not report that
    /// key.
    public func merging(_ provided: [String: String]) -> [String: String] {
        context.merging(provided) { _, fromProvider in fromProvider }
    }

    // MARK: - Parsing

    /// An env var set to the empty string means UNSET, not "". A launcher that
    /// builds its env dict programmatically writes `ANNOTKIT_EVENTS: ""` for "no
    /// event stream" far more often than it means to open a file called "".
    private static func value(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Paths get a tilde expanded. A shell expands `~` in `VAR=~/notes.md` before
    /// the process ever sees it, but a launcher assembling a dictionary in code
    /// does not, and the failure mode is a literal `./~` directory appearing next
    /// to the app.
    private static func path(_ raw: String?) -> String? {
        value(raw).map { NSString(string: $0).expandingTildeInPath }
    }

    /// Both spellings, because they answer different needs. The `key=value` list is
    /// what a person types into a shell for one run; the per-key variables are what
    /// a launcher builds when the values are arbitrary host strings — a persona
    /// name containing a comma cannot survive the list form, and quoting rules that
    /// exist only inside an env var are a trap.
    ///
    /// Per-key wins on a collision: it is the more specific statement.
    private static func context(_ environment: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        if let list = value(environment["ANNOTKIT_CONTEXT"]) {
            for pair in list.split(separator: ",") {
                guard let split = pair.firstIndex(of: "=") else { continue }
                let key = pair[..<split].trimmingCharacters(in: .whitespaces)
                let entry = pair[pair.index(after: split)...].trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty, !entry.isEmpty else { continue }
                out[key] = entry
            }
        }
        let prefix = "ANNOTKIT_CONTEXT_"
        for (name, raw) in environment where name.hasPrefix(prefix) {
            // Lowercased: env vars are conventionally shouted, and the key travels
            // into a JSON payload and a markdown line where `PERSONA="ada"` reads
            // like a mistake. `ANNOTKIT_CONTEXT_WINDOW_SIZE` -> `window_size`.
            let key = String(name.dropFirst(prefix.count)).lowercased()
            guard !key.isEmpty, let entry = value(raw) else { continue }
            out[key] = entry
        }
        return out
    }
}
