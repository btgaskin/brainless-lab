import type { TrackingSnapshot } from '../../../simulation/tasks/tracking';
import type { Renderer } from './types';
import { BRAND_COLORS } from './types';

const EYE_OFFSETS_DEG = [30, -30];

export class TrackingRenderer implements Renderer<TrackingSnapshot> {
  draw(ctx: CanvasRenderingContext2D, snap: TrackingSnapshot): void {
    const { width, height } = ctx.canvas;
    const cx = width / 2;
    const cy = height / 2;
    const r = Math.min(width, height) * 0.38;

    ctx.clearRect(0, 0, width, height);
    ctx.fillStyle = BRAND_COLORS.paper;
    ctx.fillRect(0, 0, width, height);

    ctx.strokeStyle = BRAND_COLORS.grid;
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    ctx.arc(cx, cy, r, 0, Math.PI * 2);
    ctx.stroke();

    // eye cones: faint teal (activity), matching the agent's own accent color
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

    // stimulus: amber (source/target semantic)
    const sRad = (snap.stimulusDeg * Math.PI) / 180;
    ctx.beginPath();
    ctx.arc(cx + Math.cos(sRad) * r, cy + Math.sin(sRad) * r, 6, 0, Math.PI * 2);
    ctx.fillStyle = BRAND_COLORS.amber;
    ctx.fill();

    // agent + heading: teal (agent semantic), ink accent line for the heading tick
    ctx.strokeStyle = BRAND_COLORS.ink;
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.moveTo(cx, cy);
    ctx.lineTo(cx + Math.cos(headingRad) * 20, cy + Math.sin(headingRad) * 20);
    ctx.stroke();
    ctx.beginPath();
    ctx.arc(cx, cy, 5, 0, Math.PI * 2);
    ctx.fillStyle = BRAND_COLORS.teal;
    ctx.fill();
  }
}
