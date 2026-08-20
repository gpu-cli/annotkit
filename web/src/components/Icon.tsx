import type { LucideIcon } from "lucide-react";

/**
 * Every icon on the page comes through here, so the two numbers that decide
 * whether an icon belongs to this drawing live in one place.
 *
 * Lucide's own defaults are 24 px at stroke 2. Both are wrong here: the page
 * is set in hairlines, and a stroke-2 glyph would be the heaviest line on the
 * sheet. Stroke 1.5 puts an icon in the same weight family as the rules.
 *
 * One size, and no second: **1 em of whatever type the icon sits in**, set in
 * base.css. That is the rule the arrows already followed when they were the
 * text characters ↗ and ↓, and it is the only rule that holds across the five
 * places an icon appears — the subfoot label at 0.7 rem, the copy button at
 * 0.7 rem, the masthead nav and the theme control at 0.8 rem, and the hero
 * CTAs at 1.25 rem. Any fixed pixel value is oversized at one end of that
 * range and undersized at the other, which is exactly what happened when the
 * copy button and the theme control were pinned at 20 px: each was the
 * largest mark in a row of 11 px machine text.
 *
 * A 1 em icon does NOT mean a small tap target. `.copy` keeps its 44 px box
 * and centres an 11 px glyph in it; what the size controls is the drawing,
 * not the thing you have to hit.
 *
 * The size lives in CSS rather than on the `size` prop because Lucide's prop
 * only writes width and height attributes, which the stylesheet would have to
 * override anyway. The stroke comes from here, because there is no CSS
 * property for it that would not also reach into the code plates.
 *
 * `aria-hidden` is not optional, and that is the point. Every icon on this
 * page either repeats the word beside it or is the whole of a button that
 * already carries an `aria-label`; in both cases a name on the SVG would be a
 * duplicate read. Nothing may quietly rely on an icon to name itself.
 */

export const ICON_STROKE = 1.5;

export function Icon({ as: Glyph }: { as: LucideIcon }) {
  return (
    <Glyph strokeWidth={ICON_STROKE} className="icon" aria-hidden="true" focusable="false" />
  );
}
