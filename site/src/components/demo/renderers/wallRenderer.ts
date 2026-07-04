import type { WallSnapshot } from '../../../simulation/tasks/wall';
import type { Renderer } from './types';
import { BRAND_COLORS } from './types';

const PAD = 10;
const GRID_STEP = 3; // world units between graph-paper lines (15m box -> 5x5 cells)
const TRAIL_MAX_POINTS = 360; // ~18s of movement at 20 ticks/s
const TRAIL_BREAK_DIST_SQ = 4; // a >2m jump between frames is a reset, not motion

/**
 * The 15x15m wall-avoidance box, scaled to fill its (square) canvas frame.
 * Keeps a fading trajectory trail — the same teal-trajectory semantic as the
 * Makie extension — so the behaviour's history is visible at a glance.
 */
export class WallRenderer implements Renderer<WallSnapshot> {
  readonly aspect = 1; // 15x15m box
  private trail: number[] = []; // flat [x0, y0, x1, y1, ...] in world units

  draw(ctx: CanvasRenderingContext2D, snap: WallSnapshot, w: number, h: number): void {
    const scale = (Math.min(w, h) - PAD * 2) / snap.boxSize;
    const ox = (w - snap.boxSize * scale) / 2;
    const oy = (h - snap.boxSize * scale) / 2;
    const tx = (v: number) => ox + v * scale;
    const ty = (v: number) => oy + v * scale;

    // Trail bookkeeping (dedupes resize redraws; clears on reset teleports).
    const n = this.trail.length;
    if (n === 0) {
      this.trail.push(snap.x, snap.y);
    } else {
      const dx = snap.x - this.trail[n - 2];
      const dy = snap.y - this.trail[n - 1];
      const d2 = dx * dx + dy * dy;
      if (d2 > TRAIL_BREAK_DIST_SQ) {
        this.trail = [snap.x, snap.y];
      } else if (d2 > 1e-12) {
        this.trail.push(snap.x, snap.y);
        if (this.trail.length > TRAIL_MAX_POINTS * 2) {
          this.trail.splice(0, this.trail.length - TRAIL_MAX_POINTS * 2);
        }
      }
    }

    ctx.clearRect(0, 0, w, h);
    ctx.fillStyle = BRAND_COLORS.card;
    ctx.fillRect(0, 0, w, h);

    // Graph-paper grid inside the arena.
    ctx.strokeStyle = BRAND_COLORS.grid;
    ctx.lineWidth = 1;
    ctx.globalAlpha = 0.45;
    for (let g = GRID_STEP; g < snap.boxSize; g += GRID_STEP) {
      ctx.beginPath();
      ctx.moveTo(tx(g), ty(0));
      ctx.lineTo(tx(g), ty(snap.boxSize));
      ctx.stroke();
      ctx.beginPath();
      ctx.moveTo(tx(0), ty(g));
      ctx.lineTo(tx(snap.boxSize), ty(g));
      ctx.stroke();
    }
    ctx.globalAlpha = 1;

    // Trajectory trail: faint teal polyline.
    if (this.trail.length >= 4) {
      ctx.strokeStyle = `${BRAND_COLORS.teal}3d`;
      ctx.lineWidth = 1.5;
      ctx.lineJoin = 'round';
      ctx.beginPath();
      ctx.moveTo(tx(this.trail[0]), ty(this.trail[1]));
      for (let i = 2; i < this.trail.length; i += 2) {
        ctx.lineTo(tx(this.trail[i]), ty(this.trail[i + 1]));
      }
      ctx.stroke();
    }

    // Arena walls.
    ctx.strokeStyle = BRAND_COLORS.grid;
    ctx.lineWidth = 1.5;
    ctx.strokeRect(tx(0), ty(0), snap.boxSize * scale, snap.boxSize * scale);

    const ax = tx(snap.x);
    const ay = ty(snap.y);
    const agentR = Math.max(4, 0.5 * scale);

    // Sensor rays: faint teal (activity) normally, amber when a collision fires.
    ctx.strokeStyle = snap.collided ? `${BRAND_COLORS.amber}cc` : `${BRAND_COLORS.tealSoft}88`;
    ctx.lineWidth = 1.5;
    for (const off of [Math.PI / 4, -Math.PI / 4]) {
      const a = snap.headingRad + off;
      const sx = ax + Math.cos(a) * agentR;
      const sy = ay + Math.sin(a) * agentR;
      ctx.beginPath();
      ctx.moveTo(sx, sy);
      ctx.lineTo(sx + Math.cos(a) * scale * 3, sy + Math.sin(a) * scale * 3);
      ctx.stroke();
    }

    // Agent: teal (matches _draw_agent_boids! in the Makie extension); amber on collision.
    ctx.beginPath();
    ctx.arc(ax, ay, agentR, 0, Math.PI * 2);
    ctx.fillStyle = snap.collided ? BRAND_COLORS.amber : BRAND_COLORS.teal;
    ctx.fill();

    ctx.strokeStyle = BRAND_COLORS.ink;
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.moveTo(ax, ay);
    ctx.lineTo(ax + Math.cos(snap.headingRad) * agentR * 1.8, ay + Math.sin(snap.headingRad) * agentR * 1.8);
    ctx.stroke();
  }
}
