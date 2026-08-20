/**
 * Single source of truth for every string on the page (epic §8.1).
 *
 * Honest-copy rule (epic §6.6, Hallmark gate 46): every claim here is
 * traceable to README.md, DECISIONS.md, or Package.swift. No metrics, no
 * testimonials, no logo walls — AnnotKit is a pre-1.0, MIT, single-maintainer
 * Swift package and the page says so.
 *
 * Typography: curly quotes and ellipses are written as the real characters,
 * never as `"` or `...`.
 *
 * No em dashes. Not for typographic reasons but for voice: a page whose every
 * other sentence pivots on a dash reads as machine-written, and this one is
 * arguing that a human looked at the thing. Where a dash was doing real work
 * the sentence was recast to want a colon, a comma, or a full stop, rather
 * than having one substituted under it. Code comments still use them; they
 * are not the copy.
 */

export const meta = {
  title: "AnnotKit: native annotation for AI coding agents",
  description:
    "A Swift package for macOS and iOS apps. Click a view in your own dev build, type a note, and hand your coding agent a selector it can trace back to code. MIT, Swift 6, pre-1.0.",
} as const;

export const masthead = {
  dateline: "A Swift package: native annotation for AI coding agents",
  facts: ["macOS 15", "iOS 17", "Swift 6", "MIT"],
  wordmark: "AnnotKit",
  /**
   * Labels only. The trailing marks used to live in these strings as the
   * characters ↗ and ↓; they are Lucide glyphs now, rendered beside the
   * label rather than baked into it, so the accessible name of each link is
   * the word alone.
   */
  links: {
    github: "GitHub",
    githubUnavailable: "GitHub (private for now)",
    updates: "Updates",
  },
} as const;

export const hero = {
  display: "Point at the view. Hand the agent the map.",
  standfirst:
    "AnnotKit is a Swift package that mounts a floating toolbar in the dev build of your macOS or iOS app. Click a control, or draw a frame around a whole card, then type a note. It writes an agent-readable annotation: a stable selector, an element path, the element’s role and text, and your words. Your coding agent stops guessing.",
  ctaPrimary: "Read the README",
  ctaSecondary: "Get release notes",
} as const;

export const install = {
  number: "§01",
  title: "Install",
  lead: "Add the Swift package. Mount the toolbar. Two lines, dev builds only.",
  appKit: {
    caption: "AppKit / SwiftUI on macOS",
    code: `import AnnotKit

#if DEBUG
Annotation.install()   // floating toolbar; click a view, type a note
#endif`,
  },
  swiftUI: {
    caption: "SwiftUI on iOS: attach it to a view",
    code: `ContentView()
    #if DEBUG
    .installAnnotation()
    #endif`,
  },
  sinkNote:
    "`install()` reads the accessibility tree on macOS and walks the view hierarchy on iOS, and writes notes to `ANNOTKIT_NOTES.md` in the working directory. Pass a different sink to override:",
  sink: {
    caption: "Override the sink",
    code: `Annotation.install(sink: ClipboardSink(format: .json))`,
  },
} as const;

export const annotate = {
  number: "§02",
  title: "Annotate",
  lead: "A click means this exact spot: AnnotKit descends to the deepest actionable control. A drawn frame means this whole thing: the largest element the frame surrounds wins. One rule, both platforms. The selector anchors itself to the nearest `accessibilityIdentifier`, so it round-trips back to code.",
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
      body: "An unidentified target is anchored to its nearest seeded identifier (`#Settings.Profile >> @Save`), so the selector points an agent at the right component’s code.",
    },
  ],
} as const;

export const agentNotes = {
  number: "§03",
  title: "Hand it to the agent",
  lead: "Notes land in `ANNOTKIT_NOTES.md`, one markdown block per note, headed by the selector that located it. They can go to the clipboard instead, or out as JSON.",
  /**
   * Verbatim `AnnotationFormatter` output for a SEEDED button. Seeded on
   * purpose: an unseeded target adds a 150-character `**Unseeded**` hint line,
   * and the plate scrolls rather than wraps, so that one line would push the
   * whole sample off the page.
   */
  sample: {
    caption: "The block `AnnotationFormatter` writes, one per note",
    code: `## [3f9c1a] Settings - #Settings.Profile.Save
**Timestamp**: 2026-08-19T09:14:02Z
**Element Path**: AXWindow[0] > #Settings.Profile > #Settings.Profile.Save
**Component**: #Settings.Profile.Save
**Element**: AXButton "Save"

This button should stay disabled until the name field
is non-empty. Right now it saves an empty profile.`,
  },
  sinks: [
    {
      term: "`NotesFileSink`",
      body: "Rewrites `ANNOTKIT_NOTES.md` with the full set of notes on every save. The default.",
    },
    {
      term: "`ClipboardSink`",
      body: "Copies the note as markdown or JSON. Nothing on disk.",
    },
    {
      term: "`JSONFileSink`",
      body: "Writes `ANNOTKIT_NOTES.json`, the input the MCP bridge reads.",
    },
  ],
} as const;

export const mcpBridge = {
  number: "§04",
  title: "Ask over MCP",
  lead: "Run the optional bridge and let the agent ask what’s pending.",
  command: {
    caption: "Run it beside your app",
    code: `swift run annotkit-mcp path/to/ANNOTKIT_NOTES.json`,
  },
  tools: [
    { term: "`annotation_get_pending`", body: "Every note the agent hasn’t resolved yet." },
    { term: "`annotation_resolve`", body: "Mark one done once the code has changed." },
  ],
} as const;

export const signup = {
  number: "§05",
  title: "One email when it’s worth reading.",
  lead: "The GPU CLI list: releases and design notes for AnnotKit, for the CLI that runs cloud GPUs from your terminal, and for whatever ships next. No digest, no drip campaign.",
  label: "Email address",
  placeholder: "you@example.com",
  submit: "Get release notes",
  submitLoading: "Subscribing…",
  helper: "One address. Nothing else asked for.",
  successNew: "You’re on the list.",
  successDuplicate: "You’re already on the list.",
  successBody: "Next mail goes out when there’s a release worth reading.",
  errors: {
    invalid_email: "That address doesn’t parse. Check for typos.",
    rate_limited: "Slow down. Try again shortly.",
    upstream: "Something broke on our side. Try again in a minute.",
    network: "That didn’t reach us. Check your connection and try again.",
  },
  privacy:
    "One list for everything GPU CLI ships, AnnotKit included. Your address goes to Resend and nowhere else, and every email carries an unsubscribe link.",
} as const;

/**
 * The theme control. Both the visible word and the accessible name state the
 * mode the button switches TO, because that is what pressing it does.
 *
 * The two are worded to overlap on purpose: WCAG 2.5.3 wants a control's
 * accessible name to CONTAIN its visible label, so someone driving the page
 * by voice can say what they can see. "Switch to the dark theme" beside a
 * button reading "Dark Mode" would have failed that; "Switch to dark mode"
 * does not.
 */
export const theme = {
  /** The visible label. Both are rendered at once and one is hidden — see
   * ThemeToggle — so the row cannot change width when the mode flips. */
  mode: {
    dark: "Dark Mode",
    light: "Light Mode",
  },
  switchTo: {
    dark: "Switch to dark mode",
    light: "Switch to light mode",
  },
} as const;

export const footer = {
  wordmark: "AnnotKit",
  poweredBy: "Powered by GPU CLI",
  /**
   * One sentence per line, set as separate blocks rather than left to wrap.
   * At `--measure-narrow` the natural break landed inside the second clause,
   * and no measure inside the 45–75 ch band moves it to the sentence
   * boundary.
   *
   * The first line no longer positions AnnotKit against Agentation. It says
   * what the tool does instead, which is both what the maintainer asked for
   * and the stronger line — a product that defines itself by a comparison is
   * borrowing someone else's noun.
   */
  tagline: [
    "Point at a view, leave a note your agent can act on.",
    "Pre-1.0. The API may still shift.",
  ],
  links: [
    { label: "GitHub", href: "repo" },
    { label: "Issues", href: "issues" },
  ],
  /** The typographic colophon only. Licence terms live in the repo. */
  colophon: "Set in Fraunces, Newsreader & IBM Plex Mono.",
} as const;

/**
 * The copy button is a bare icon now, so none of these are visible labels any
 * more. `copyLabel` is the button's accessible name and the three outcome
 * strings are what the live region announces; the Copy and Check glyphs are
 * what a sighted reader sees. Keeping the words here rather than deleting
 * them is the point — an icon-only control still has to say what it did.
 */
export const codeBlock = {
  copy: "Copy",
  copied: "Copied",
  failed: "Copy failed",
  /** The button's accessible name, in every state. */
  copyLabel: (caption: string) => `Copy the ${caption} snippet`,
} as const;

export const skipLink = "Skip to content";
