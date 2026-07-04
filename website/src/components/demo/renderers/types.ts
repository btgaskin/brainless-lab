/**
 * Every renderer takes plain data (`Snap`) and draws it — never a reference
 * into simulation/'s internal classes/state. This keeps rendering fully
 * decoupled from the simulation: a Three.js renderer could implement the same
 * interface later without touching simulation/ or the sim loop at all.
 */
export interface Renderer<Snap> {
  draw(ctx: CanvasRenderingContext2D, snap: Snap): void;
  resize?(width: number, height: number): void;
}

/**
 * The Julia package's own visual identity — src/viz/Style.jl's BL_*
 * constants, used consistently by ext/BrainlessLabMakieExt.jl for these same
 * task environments (wall/tracking/pong). Kept here as literal hex values
 * (not Tailwind classes) since Canvas2D needs them directly. Semantic
 * mapping, matching the Makie extension exactly: agents/trajectories=teal,
 * source/target/stimulus/warn=amber, structure=ink, surface=paper.
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
