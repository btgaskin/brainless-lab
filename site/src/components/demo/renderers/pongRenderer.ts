import type { PongSnapshot } from '../../../simulation/tasks/pong';
import type { Renderer } from './types';
import { BRAND_COLORS } from './types';

const PAD = 10;
const TRAIL_MAX = 14;
const TRAIL_BREAK_DIST = 60; // world px — a jump this big is a ball reset

/**
 * The 1000x500 pong arena, scaled to fill its (2:1) canvas frame, with a
 * dashed goal line at the paddle's x and a fading amber ball trail.
 */
export class PongRenderer implements Renderer<PongSnapshot> {
  readonly aspect = 2; // 1000x500 arena
  private trail: number[] = []; // flat [x0, y0, ...] in world px, oldest first

  draw(ctx: CanvasRenderingContext2D, snap: PongSnapshot, w: number, h: number): void {
    const scale = Math.min((w - PAD * 2) / snap.arenaW, (h - PAD * 2) / snap.arenaH);
    const ox = (w - snap.arenaW * scale) / 2;
    const oy = (h - snap.arenaH * scale) / 2;
    const tx = (v: number) => ox + v * scale;
    const ty = (v: number) => oy + v * scale;

    // Ball-trail bookkeeping.
    const n = this.trail.length;
    if (n === 0) {
      this.trail.push(snap.ballX, snap.ballY);
    } else {
      const dx = snap.ballX - this.trail[n - 2];
      const dy = snap.ballY - this.trail[n - 1];
      const d2 = dx * dx + dy * dy;
      if (d2 > TRAIL_BREAK_DIST * TRAIL_BREAK_DIST) {
        this.trail = [snap.ballX, snap.ballY];
      } else if (d2 > 1e-9) {
        this.trail.push(snap.ballX, snap.ballY);
        if (this.trail.length > TRAIL_MAX * 2) this.trail.splice(0, this.trail.length - TRAIL_MAX * 2);
      }
    }

    ctx.clearRect(0, 0, w, h);
    ctx.fillStyle = BRAND_COLORS.card;
    ctx.fillRect(0, 0, w, h);

    // Arena bounds.
    ctx.strokeStyle = BRAND_COLORS.grid;
    ctx.lineWidth = 1.5;
    ctx.strokeRect(tx(0), ty(0), snap.arenaW * scale, snap.arenaH * scale);

    // Goal line at the paddle's x.
    ctx.save();
    ctx.setLineDash([5, 5]);
    ctx.globalAlpha = 0.6;
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(tx(snap.paddleX), ty(0));
    ctx.lineTo(tx(snap.paddleX), ty(snap.arenaH));
    ctx.stroke();
    ctx.restore();

    // Ball trail: fading amber dots.
    const len = this.trail.length / 2;
    ctx.fillStyle = BRAND_COLORS.amber;
    for (let i = 0; i < len - 1; i++) {
      ctx.globalAlpha = 0.05 + 0.22 * (i / len);
      ctx.beginPath();
      ctx.arc(tx(this.trail[i * 2]), ty(this.trail[i * 2 + 1]), snap.ballR * scale * 0.55, 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.globalAlpha = 1;

    // Paddle: teal (agent semantic), rounded.
    ctx.fillStyle = BRAND_COLORS.teal;
    const px = tx(snap.paddleX) - 4;
    const py = ty(snap.paddleY);
    const ph = snap.paddleH * scale;
    if (typeof ctx.roundRect === 'function') {
      ctx.beginPath();
      ctx.roundRect(px, py, 6, ph, 3);
      ctx.fill();
    } else {
      ctx.fillRect(px, py, 6, ph);
    }

    // Ball: amber (stimulus/target semantic).
    ctx.beginPath();
    ctx.arc(tx(snap.ballX), ty(snap.ballY), snap.ballR * scale, 0, Math.PI * 2);
    ctx.fillStyle = BRAND_COLORS.amber;
    ctx.fill();
  }
}
