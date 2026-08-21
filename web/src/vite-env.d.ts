/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_SITE_URL?: string;
  readonly VITE_POSTHOG_KEY?: string;
  readonly VITE_POSTHOG_HOST?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}

declare module "virtual:highlighted" {
  /** `plugins/highlight.ts`: snippet key → Shiki inline HTML. */
  const highlighted: Record<string, string>;
  export default highlighted;
}
