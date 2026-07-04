import type { TrackingSnapshot } from '../../../simulation/tasks/tracking';
import type { Renderer } from './types';
import { BRAND_COLORS } from './types';

const EYE_OFFSETS_DEG = [30, -30];
const PAD = 18;
const TRAIL_MAX = 40;
const TRAIL_BREAK_DEG = 25; // a jump this big is a reset, not stimulus motion

/**
 * The 1D tracking task drawn as a dial: agent at the center, stimulus on the
 * ring, with a fading amber trail of the stimulus's recent positions.
 */
export class TrackingRenderer implements Renderer<TrackingSnapshot> {
  readonly aspect = 1; // dial
  private stimTrail: number[] = []; // degrees, oldest first

  draw(ctx: CanvasRenderingContext2D, snap: TrackingSnapshot, w: number, h: number): void {
    const cx = w / 2;
    const cy = h / 2;
    const r = Math.min(w, h) / 2 - PAD;

    // Stimulus-trail bookkeeping.
    const n = this.stimTrail.length;
    if (n === 0 || this.stimTrail[n - 1] !== snap.stimulusDeg) {
      if (n > 0) {
        let dd = Math.abs(snap.stimulusDeg - this.stimTrail[n - 1]) % 360;
        if (dd > 180) dd = 360 - dd;
        if (dd > TRAIL_BREAK_DEG) this.stimTrail = [];
      }
      this.stimTrail.push(snap.stimulusDeg);
      if (this.stimTrail.length > TRAIL_MAX) this.stimTrail.splice(0, this.stimTrail.length - TRAIL_MAX);
    }

    ctx.clearRect(0, 0, w, h);
    ctx.fillStyle = BRAND_COLORS.card;
    ctx.fillRect(0, 0, w, h);

    // Dial ring + 30-degree ticks.
    ctx.strokeStyle = BRAND_COLORS.grid;
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    ctx.arc(cx, cy, r, 0, Math.PI * 2);
    ctx.stroke();
    ctx.lineWidth = 1;
    ctx.globalAlpha = 0.6;
    for (let deg = 0; deg < 360; deg += 30) {
      const a = (deg * Math.PI) / 180;
      ctx.beginPath();
      ctx.moveTo(cx + Math.cos(a) * (r - 6), cy + Math.sin(a) * (r - 6));
      ctx.lineTo(cx + Math.cos(a) * r, cy + Math.sin(a) * r);
      ctx.stroke();
    }
    ctx.globalAlpha = 1;

    // Eye cones: faint teal (activity), matching the agent's own accent color.
    const headingRad = (snap.headingDeg * Math.PI) / 180;
    ctx.strokeStyle = `${BRAND_COLORS.tealSoft}55`;
    ctx.lineWidth = 1;
    for (const eyeOffsetDeg of EYE_OFFSETS_DEG) {
      const a = headingRad + (eyeOffsetDeg * Math.PI) / 180;
      ctx.beginPath();
      ctx.moveTo(cx, cy);
      ctx.lineTo(cx + Math.cos(a) * r, cy + Math.sin(a) * r);
      ctx.stroke();
    }

    // Stimulus trail: fading amber dots along the ring (newest excluded — the
    // live stimulus dot covers it).
    const len = this.stimTrail.length;
    ctx.fillStyle = BRAND_COLORS.amber;
    for (let i = 0; i < len - 1; i++) {
      const a = (this.stimTrail[i] * Math.PI) / 180;
      ctx.globalAlpha = 0.06 + 0.28 * (i / len);
      ctx.beginPath();
      ctx.arc(cx + Math.cos(a) * r, cy + Math.sin(a) * r, 2.5, 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.globalAlpha = 1;

    // Stimulus: amber (source/target semantic), lifted off the ring with a card-colored halo.
    const sRad = (snap.stimulusDeg * Math.PI) / 180;
    const sx = cx + Math.cos(sRad) * r;
    const sy = cy + Math.sin(sRad) * r;
    ctx.beginPath();
    ctx.arc(sx, sy, 6, 0, Math.PI * 2);
    ctx.fillStyle = BRAND_COLORS.amber;
    ctx.fill();
    ctx.strokeStyle = BRAND_COLORS.card;
    ctx.lineWidth = 2;
    ctx.stroke();

    // Agent + heading: teal (agent semantic), ink accent line for the heading tick.
    ctx.strokeStyle = BRAND_COLORS.ink;
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.moveTo(cx, cy);
    ctx.lineTo(cx + Math.cos(headingRad) * r * 0.32, cy + Math.sin(headingRad) * r * 0.32);
    ctx.stroke();
    ctx.beginPath();
    ctx.arc(cx, cy, 6, 0, Math.PI * 2);
    ctx.fillStyle = BRAND_COLORS.teal;
    ctx.fill();
  }
}
