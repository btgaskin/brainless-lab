import type { PlankCartPoleSnapshot } from '../../../simulation/tasks/cartpolePlank';
import type { Renderer } from './types';
import { BRAND_COLORS } from './types';

const PAD_X = 24;
const LEVEL_ORDER = ['easy', 'medium', 'hard', 'hardest'] as const;

/**
 * One renderer for the four Plank levels. The physical world is shared; the
 * compact header exposes the level's frozen observation/action/encoder
 * interface and the current mission state.
 */
export class CartPoleRenderer implements Renderer<PlankCartPoleSnapshot> {
  readonly aspect = 1.6;

  draw(ctx: CanvasRenderingContext2D, snap: PlankCartPoleSnapshot, w: number, h: number): void {
    ctx.clearRect(0, 0, w, h);
    ctx.fillStyle = BRAND_COLORS.card;
    ctx.fillRect(0, 0, w, h);

    const headerY = 22;
    const trackY = h * 0.72;
    const usableW = w - PAD_X * 2;
    const tx = (x: number) => w / 2 + (x / snap.maxX) * (usableW / 2);
    const polePixels = Math.min(h * 0.38, usableW * 0.22);
    const cartX = tx(snap.x);

    this.drawHeader(ctx, snap, w, headerY);

    // Threshold guides and a light centre line make cart displacement legible.
    ctx.save();
    ctx.strokeStyle = BRAND_COLORS.grid;
    ctx.lineWidth = 1;
    ctx.setLineDash([3, 5]);
    for (const x of [tx(-snap.maxX), tx(0), tx(snap.maxX)]) {
      ctx.beginPath();
      ctx.moveTo(x, headerY + 28);
      ctx.lineTo(x, trackY + 14);
      ctx.stroke();
    }
    ctx.restore();

    // Track, end stops, and a compact mission-progress rail.
    ctx.strokeStyle = BRAND_COLORS.grid;
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.moveTo(PAD_X, trackY);
    ctx.lineTo(w - PAD_X, trackY);
    ctx.stroke();
    ctx.strokeStyle = BRAND_COLORS.amberSoft;
    ctx.lineWidth = 2;
    for (const x of [PAD_X, w - PAD_X]) {
      ctx.beginPath();
      ctx.moveTo(x, trackY - 9);
      ctx.lineTo(x, trackY + 9);
      ctx.stroke();
    }

    const progress = Math.min(1, snap.stepCount / snap.missionSteps);
    ctx.fillStyle = BRAND_COLORS.grid;
    ctx.fillRect(PAD_X, h - 18, usableW, 2);
    ctx.fillStyle = snap.done ? BRAND_COLORS.amber : BRAND_COLORS.tealSoft;
    ctx.fillRect(PAD_X, h - 18, usableW * progress, 2);

    // Cart body.
    const cartW = Math.max(26, Math.min(44, w * 0.11));
    const cartH = Math.max(13, cartW * 0.42);
    ctx.fillStyle = snap.done ? BRAND_COLORS.amberSoft : BRAND_COLORS.tealSoft;
    ctx.strokeStyle = snap.done ? BRAND_COLORS.amber : BRAND_COLORS.teal;
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    if (typeof ctx.roundRect === 'function') {
      ctx.roundRect(cartX - cartW / 2, trackY - cartH / 2, cartW, cartH, 3);
    } else {
      ctx.rect(cartX - cartW / 2, trackY - cartH / 2, cartW, cartH);
    }
    ctx.fill();
    ctx.stroke();

    // Pole angle follows the Julia scene convention: theta=0 is upright.
    const tipX = cartX + polePixels * Math.sin(snap.theta);
    const tipY = trackY - polePixels * Math.cos(snap.theta);
    ctx.strokeStyle = snap.done ? BRAND_COLORS.amber : BRAND_COLORS.teal;
    ctx.lineWidth = 5;
    ctx.lineCap = 'round';
    ctx.beginPath();
    ctx.moveTo(cartX, trackY);
    ctx.lineTo(tipX, tipY);
    ctx.stroke();
    ctx.beginPath();
    ctx.arc(tipX, tipY, 6, 0, Math.PI * 2);
    ctx.fillStyle = snap.done ? BRAND_COLORS.amber : BRAND_COLORS.teal;
    ctx.fill();
    ctx.strokeStyle = BRAND_COLORS.card;
    ctx.lineWidth = 1.5;
    ctx.stroke();

    // Action cue below the cart. No-op is a centred dot; force is an arrow.
    const actionY = trackY + 24;
    ctx.fillStyle = snap.done ? BRAND_COLORS.inkMuted : BRAND_COLORS.inkSoft;
    ctx.strokeStyle = snap.done ? BRAND_COLORS.inkMuted : BRAND_COLORS.inkSoft;
    ctx.lineWidth = 1.5;
    if (snap.lastAction === null) {
      // No command has been selected before the first world step.
    } else if (snap.lastAction === 'noop') {
      ctx.beginPath();
      ctx.arc(cartX, actionY, 2.5, 0, Math.PI * 2);
      ctx.fill();
    } else {
      const direction = snap.lastAction === 'left' ? -1 : 1;
      const endX = cartX + direction * 22;
      ctx.beginPath();
      ctx.moveTo(cartX, actionY);
      ctx.lineTo(endX, actionY);
      ctx.lineTo(endX - direction * 5, actionY - 4);
      ctx.moveTo(endX, actionY);
      ctx.lineTo(endX - direction * 5, actionY + 4);
      ctx.stroke();
    }

    ctx.font = '10px ui-monospace, SFMono-Regular, Menlo, monospace';
    ctx.fillStyle = snap.done ? BRAND_COLORS.amber : BRAND_COLORS.inkMuted;
    ctx.textAlign = 'left';
    ctx.fillText(snap.done ? `FELL · ${snap.stepCount} STEPS` : `${snap.stepCount} / ${snap.missionSteps}`, PAD_X, h - 27);
    ctx.textAlign = 'right';
    const angle = (snap.theta * 180) / Math.PI;
    const mediumStatus =
      snap.level === 'medium' ? ` · NO-OP ${(snap.noopFraction * 100).toFixed(0)}%` : '';
    ctx.fillText(`θ ${angle.toFixed(1)}°${mediumStatus}`, w - PAD_X, h - 27);
  }

  private drawHeader(
    ctx: CanvasRenderingContext2D,
    snap: PlankCartPoleSnapshot,
    w: number,
    y: number,
  ): void {
    ctx.textBaseline = 'middle';
    ctx.textAlign = 'left';
    ctx.fillStyle = BRAND_COLORS.ink;
    ctx.font = '600 11px ui-monospace, SFMono-Regular, Menlo, monospace';
    ctx.fillText(`PLANK · ${snap.levelLabel.toUpperCase()}`, PAD_X, y);

    ctx.textAlign = 'right';
    ctx.fillStyle = snap.done ? BRAND_COLORS.amber : BRAND_COLORS.inkMuted;
    ctx.font = '10px ui-monospace, SFMono-Regular, Menlo, monospace';
    ctx.fillText(
      snap.done ? 'TERMINAL' : snap.lastAction === null ? 'READY' : snap.lastAction.toUpperCase(),
      w - PAD_X,
      y,
    );

    const levelIndex = LEVEL_ORDER.indexOf(snap.level);
    for (let index = 0; index < LEVEL_ORDER.length; index++) {
      ctx.beginPath();
      ctx.arc(PAD_X + index * 9, y + 16, 2.2, 0, Math.PI * 2);
      ctx.fillStyle = index <= levelIndex ? BRAND_COLORS.tealSoft : BRAND_COLORS.grid;
      ctx.fill();
    }

    const encoder = snap.encoder === 'spike_ff_2' ? 'SPIKE-FF-2' : 'ARGYLE-4';
    ctx.textAlign = 'right';
    ctx.fillStyle = BRAND_COLORS.inkMuted;
    ctx.font = '9px ui-monospace, SFMono-Regular, Menlo, monospace';
    ctx.fillText(`${snap.observationLabel} · ${snap.actionCount} ACTIONS · ${encoder}`, w - PAD_X, y + 16);
    ctx.textBaseline = 'alphabetic';
  }
}
