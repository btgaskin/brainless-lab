/**
 * Every renderer takes plain data (`Snap`) and draws it — never a reference
 * into a live world's internal state. Rendering consumes recorded scene values
 * and contains no neural or world update equations.
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
 * Neutral colours for recorded scenes. Canvas2D needs literal colour values.
 * Separate grey tones distinguish agents, trajectories and stimuli.
 */
export const BRAND_COLORS = {
  paper: '#f8f8f6',
  card: '#ffffff',
  grid: '#dfdfdc',
  ink: '#262626',
  inkSoft: '#5d5d5d',
  inkMuted: '#828282',
  teal: '#444444',
  tealSoft: '#737373',
  amber: '#666666',
  amberSoft: '#999999',
} as const;
