# Embedding AnnotKit in a multi-instance host

This is the contract between an app that launches **many isolated instances of
itself** — a design loop with one HMR session per branch, a warm gallery host, an
inspect window per persona — and the agent that reads the notes people leave in
them.

The problem it solves is narrow and specific. There is one binary and N launches,
so the thing that knows *which world this process is* and *where its notes belong*
is the launcher, not any call site in the app. AnnotKit therefore takes all of it
from the environment.

## The three things an instance needs

| | | |
|---|---|---|
| **Reproduce** | the agent can put back the world the note was made in | world context on every note |
| **Locate** | the notes land where the launching session chose | env-named destinations |
| **React** | the agent hears about a note without being told | an append-only event stream |

## Launch environment

| Variable | Effect |
|---|---|
| `ANNOTKIT_ENABLE` | mount the overlay even in a release build |
| `ANNOTKIT_DISABLE` | never mount, whatever the build (wins over `ANNOTKIT_ENABLE`) |
| `ANNOTKIT_NOTES_MD` | markdown snapshot path (default `AGENTATION_NOTES.md`) |
| `ANNOTKIT_NOTES` | JSON store path — the file `annotkit-mcp` serves |
| `ANNOTKIT_EVENTS` | append-only JSONL event stream |
| `ANNOTKIT_ROUTE` | the note's `route` when the host supplies none |
| `ANNOTKIT_CONTEXT` | world context as `key=value,key=value` |
| `ANNOTKIT_CONTEXT_<KEY>` | one world-context entry, key lowercased (wins over the list) |

A value set to the empty string means *unset*. Paths get `~` expanded; relative
paths are relative to the instance's working directory. Nothing but the markdown
snapshot is written unless you ask for it.

`ANNOTKIT_NOTES` names the **JSON store** and not the markdown one because
`annotkit-mcp` already reads that variable for exactly that file. One variable,
one file: wire an instance to its agent by setting `ANNOTKIT_NOTES` once and
passing the same environment to both processes.

```sh
ANNOTKIT_NOTES_MD=$WORLD/notes.md \
ANNOTKIT_NOTES=$WORLD/notes.json \
ANNOTKIT_EVENTS=$WORLD/events.jsonl \
ANNOTKIT_ROUTE=Settings/Models \
ANNOTKIT_CONTEXT_PERSONA=ada \
ANNOTKIT_CONTEXT="appearance=dark,build=$SHA" \
  ./MyApp
```

The app's own code stays the same for every instance:

```swift
#if DEBUG
Annotation.install(
    context: { ["appearance": appearanceName, "window": "\(width)x\(height)"] }
)
#endif
```

## World context

Context is an opaque `[String: String]`. AnnotKit does not know what a persona is
and will not learn — the keys are your vocabulary, and the agent reading the note
is the thing that understands them.

The launcher's `ANNOTKIT_CONTEXT*` values and the provider registered at
`install()` are **merged, and the provider wins** on a shared key. The provider
runs at capture and the environment was frozen at launch, so on a key both supply
the provider is simply the newer measurement: a launcher that declared
`appearance=dark` is describing how it started the app, while a provider reporting
`appearance=light` is describing what the person was actually looking at. A host
that wants the launcher's value to stand just doesn't report that key.

The snapshot is taken **per note**, not once at install, so toggling dark mode
between two notes files them under two different worlds — correctly.

It reaches the agent through all three surfaces:

```
## [355f70] Settings/Models - #SaveButton
**Timestamp**: 2026-08-19T21:42:19Z
**Context**: appearance="dark", build="hmr-7", persona="ada", window="400x300"
```

```json
{ "id": "355f70", "context": { "persona": "ada", "appearance": "dark" }, … }
```

```
[355f70] #SaveButton (AXWindow[0] > #SaveButton): contrast is too low here
    context: appearance=dark build=hmr-7 persona=ada window=400x300
```

## Watching the stream

The snapshot sinks are unwatchable by design: `NotesFileSink` writes atomically,
renaming a temporary file over the destination, so a reader never sees half a
document — and `tail -f`, which follows the inode it opened, goes silent the first
time the file is replaced underneath it.

`ANNOTKIT_EVENTS` adds an append-only JSONL log beside the snapshot. One line per
capture, edit and delete:

```jsonl
{"event":"captured","id":"355f70","note":{…},"snapshot":"/w/ada/notes.md","timestamp":"…"}
{"event":"edited","id":"355f70","note":{…},"snapshot":"/w/ada/notes.md","timestamp":"…"}
```

```sh
tail -F "$WORLD/events.jsonl" | while read -r line; do
  snapshot=$(printf '%s' "$line" | jq -r .snapshot)
  # ...wake the agent and hand it $snapshot
done
```

Three properties worth relying on:

- **The stream only wakes the reader; the snapshot is the source of truth.** Both
  are written by the same flush, so a watcher that reacts to a line and then reads
  the snapshot always finds the note that woke it. Do not reconstruct state by
  replaying the log — it would double-count edits and resurrect deletes. The
  `process-agentation-notes` skill still reads the markdown.
- **Events are derived by diffing each export**, not pushed from each keystroke. A
  note typed but not yet sent produces no line, and a re-export that changed
  nothing appends nothing. Moving a note on screen (a scroll) is not an edit —
  only a change to what the agent can *see* counts.
- **A fleet can share one log.** Lines are written with a single `O_APPEND`
  `write(2)`, so several instances can append to the same file without tearing
  each other's lines, and each line names its own world's snapshot. One `tail -F`
  covers the fleet.

## Isolation

Two instances given different paths never touch each other's files: every
destination is per-instance, and the JSON store merges by note id rather than
appending, so re-exporting a set replaces it instead of duplicating it.

`AnnotKitEnvProbe` is one such instance with the human taken out — it mounts
through the same `Annotation.install` path, captures a note in code, and exports.
`AgentLoopE2ETests` launches two of them at once and asserts everything on this
page from outside the processes.

```sh
swift run AnnotKitEnvProbe   # with the environment above
swift test --filter AgentLoopE2ETests
```
