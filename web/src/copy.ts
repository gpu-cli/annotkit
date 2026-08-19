/**
 * Single source of truth for every string on the page (epic §8.1).
 *
 * Honest-copy rule (epic §6.6, Hallmark gate 46): every claim here is
 * traceable to README.md, DECISIONS.md, or Package.swift. No metrics, no
 * testimonials, no logo walls — AnnotKit is a pre-1.0, MIT, single-maintainer
 * Swift package and the page says so.
 *
 * Typography: curly quotes, em-dashes, and ellipses are written as the real
 * characters, never as `"`, `--`, or `...`.
 */

export const meta = {
  title: "AnnotKit — native annotation for AI coding agents",
  description:
    "Click a view in your own macOS or iOS app, type a note, and hand your coding agent a selector it can trace back to code. MIT, Swift 6, pre-1.0.",
} as const;

export const masthead = {
  dateline: "Native annotation for AI coding agents",
  facts: ["macOS 15", "iOS 17", "Swift 6", "MIT"],
  wordmark: "AnnotKit",
  links: {
    github: "GitHub ↗",
    githubUnavailable: "GitHub — private for now",
    updates: "Updates ↓",
  },
} as const;

export const hero = {
  display: "Point at the view. Hand the agent the map.",
  standfirst:
    "AnnotKit mounts a floating toolbar in your dev build. Click a control — or draw a frame around a whole card — type a note, and it writes an agent-readable annotation: a stable selector, an element path, a screenshot, and your words. Your coding agent stops guessing.",
  ctaPrimary: "Read the README",
  ctaSecondary: "Get release notes",
} as const;

export const install = {
  number: "§01",
  title: "Install",
  lead: "Add the package. Mount the toolbar. Two lines, dev builds only.",
  appKit: {
    caption: "AppKit / SwiftUI on macOS",
    code: `import AnnotKit

#if DEBUG
Annotation.install()   // floating toolbar; click a view, type a note
#endif`,
  },
  swiftUI: {
    caption: "SwiftUI on iOS — attach it to a view",
    code: `ContentView()
    #if DEBUG
    .installAnnotation()
    #endif`,
  },
  sinkNote:
    "install() defaults to the platform accessibility source and writes notes to AGENTATION_NOTES.md. Pass a different sink to override:",
  sink: {
    caption: "Override the sink",
    code: `Annotation.install(sink: ClipboardSink(format: .json))`,
  },
} as const;

export const annotate = {
  number: "§02",
  title: "Annotate",
  lead: "A click means this exact spot: AnnotKit descends to the deepest actionable control. A drawn frame means this whole thing: the largest element the frame surrounds wins. One rule, both platforms — the selector anchors itself to the nearest accessibilityIdentifier, so it round-trips back to code.",
  points: [
    {
      term: "Click",
      body: "Hit-test, then walk the ancestor chain. The deepest actionable control wins, so a click inside a button binds to the button and not to the label glyph underneath the pointer.",
    },
    {
      term: "Frame",
      body: "Drawing a box inverts the rule on purpose. The largest element the frame surrounds wins, the labels inside it do not, and the rect you drew rides along on the note.",
    },
    {
      term: "Anchor",
      body: "An unidentified target is anchored to its nearest seeded identifier — #Settings.Profile >> @Save — so the selector points an agent at the right component’s code.",
    },
  ],
} as const;

export const agentNotes = {
  number: "§03",
  title: "Hand it to the agent",
  lead: "Notes land in AGENTATION_NOTES.md — the format the process-agentation-notes skill consumes — or on the clipboard, or as JSON.",
  sample: {
    caption: "The block AnnotationFormatter writes, one per note",
    code: `## [n-3f9c] /settings - #Settings.Profile >> @Save
**Timestamp**: 2026-08-19T09:14:02Z
**Element Path**: Window > Settings > Profile > Save
**Component**: #Settings.Profile
**Element**: AXButton "Save"

This button should stay disabled until the name field
is non-empty. Right now it saves an empty profile.`,
  },
  sinks: [
    {
      term: "NotesFileSink",
      body: "Appends to AGENTATION_NOTES.md in the working directory. The default.",
    },
    {
      term: "ClipboardSink",
      body: "Copies the note as markdown or JSON. Nothing on disk.",
    },
    {
      term: "JSONFileSink",
      body: "Writes AGENTATION_NOTES.json — the input the MCP bridge reads.",
    },
  ],
} as const;

export const mcpBridge = {
  number: "§04",
  title: "Ask over MCP",
  lead: "Run the optional bridge and let the agent ask what’s pending.",
  command: {
    caption: "Run it beside your app",
    code: `swift run annotkit-mcp path/to/AGENTATION_NOTES.json`,
  },
  tools: [
    { term: "annotation_get_pending", body: "Every note the agent hasn’t resolved yet." },
    { term: "annotation_resolve", body: "Mark one done once the code has changed." },
  ],
} as const;

export const signup = {
  number: "§05",
  title: "One email when it’s worth reading.",
  lead: "Releases, design notes, and the 1.0 call. No digest, no drip campaign — AnnotKit is 0.x and honest about it.",
  label: "Email address",
  placeholder: "you@example.com",
  submit: "Get release notes",
  submitLoading: "Subscribing…",
  helper: "One address. Nothing else asked for.",
  successNew: "You’re on the list.",
  successDuplicate: "You’re already on the list.",
  successBody: "Next mail goes out when there’s a release worth reading.",
  errors: {
    invalid_email: "That address doesn’t parse — check for typos.",
    rate_limited: "Slow down — try again shortly.",
    upstream: "Something broke on our side. Try again in a minute.",
    network: "That didn’t reach us. Check your connection and try again.",
  },
  privacy:
    "Your address goes to Resend and nowhere else. Every email carries an unsubscribe link.",
} as const;

export const footer = {
  wordmark: "AnnotKit",
  tagline:
    "The native analogue of the web Agentation tool. Pre-1.0 — the API may shift before 1.0.",
  links: [
    { label: "GitHub", href: "repo" },
    { label: "Issues", href: "issues" },
    { label: "License", href: "license" },
  ],
  colophon:
    "MIT licensed. Reimplements the AGENTATION_NOTES.md format clean-room; contains no Agentation source. Set in Fraunces, Newsreader & IBM Plex Mono.",
} as const;

export const codeBlock = {
  copy: "Copy",
  copied: "Copied",
  failed: "Copy failed",
  /** Screen-reader name; the visible label is the short one above. */
  copyLabel: (caption: string) => `Copy the ${caption} snippet`,
} as const;

export const skipLink = "Skip to content";
