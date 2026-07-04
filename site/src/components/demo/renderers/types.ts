/**
 * Every renderer takes plain data (`Snap`) and draws it — never a reference
 * into simulation/'s internal classes/state. This keeps rendering fully
 * decoupled from the simulation: a Three.js renderer could implement the same
 * interface later without touching simulation/ or the sim loop at all.
 *
 * `width`/`height` are the canvas's *logical* (CSS-pixel) dimensions —
 * Canvas2D pre-applies the devicePixelRatio transform so renderers draw in
 * logical space and stay crisp on retina displays.
 */
export interface Renderer<Snap> {
  /** The world's width:height aspect — Canvas2D uses it to normalize every task's
   *  arena to a common footprint so switching tasks doesn't jump the size. */
  readonly aspect: number;
  draw(ctx: CanvasRenderingContext2D, snap: Snap, width: number, height: number): void;
}

/**
 * The Julia package's own visual identity — src/viz/Style.jl's BL_*
 * constants, used consistently by ext/BrainlessLabMakieExt.jl for these same
 * task environments (wall/tracking/pong). Kept here as literal hex values
 * (not Tailwind classes) since Canvas2D needs them directly. Semantic
 * mapping, matching the Makie extension exactly: agents/trajectories=teal,
 * source/target/stimulus/warn=amber, structure=ink, surface=paper/card.
 */
export const BRAND_COLORS = {
  paper: '#fbfaf7',
  card: '#ffffff',
  grid: '#dedad0',
  ink: '#24282b',
  inkSoft: '#52585d',
  inkMuted: '#82898f',
  teal: '#2f6f5e',
  tealSoft: '#659c8b',
  amber: '#9c6b1f',
  amberSoft: '#be9b5b',
} as const;
