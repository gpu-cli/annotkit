/**
 * jsdom ships no `matchMedia`. The page asks it exactly one question — does
 * the visitor prefer reduced motion — so the stub answers "no" and lets a
 * test override it per case.
 */
if (typeof window !== "undefined" && typeof window.matchMedia !== "function") {
  window.matchMedia = ((query: string) => ({
    matches: false,
    media: query,
    onchange: null,
    addEventListener: () => {},
    removeEventListener: () => {},
    addListener: () => {},
    removeListener: () => {},
    dispatchEvent: () => false,
  })) as unknown as typeof window.matchMedia;
}

/**
 * jsdom ships no `ResizeObserver`, and Radix's ScrollArea measures its
 * viewport with one. Nothing under test asserts on a resize, so the stub is
 * inert — it exists so the code blocks mount at all.
 */
if (typeof globalThis.ResizeObserver === "undefined") {
  globalThis.ResizeObserver = class {
    observe() {}
    unobserve() {}
    disconnect() {}
  } as unknown as typeof ResizeObserver;
}
