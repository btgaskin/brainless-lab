import type { WallSnapshot } from '../../../simulation/tasks/wall';
import type { Renderer } from './types';
import { BRAND_COLORS } from './types';

export class WallRenderer implements Renderer<WallSnapshot> {
  draw(ctx: CanvasRenderingContext2D, snap: WallSnapshot): void {
    const { width, height } = ctx.canvas;
    const scale = (Math.min(width, height) * 0.9) / snap.boxSize;
    const ox = (width - snap.boxSize * scale) / 2;
    const oy = (height - snap.boxSize * scale) / 2;
    const tx = (v: number) => ox + v * scale;
    const ty = (v: number) => oy + v * scale;

    ctx.clearRect(0, 0, width, height);
    ctx.fillStyle = BRAND_COLORS.paper;
    ctx.fillRect(0, 0, width, height);
    ctx.strokeStyle = BRAND_COLORS.grid;
    ctx.lineWidth = 2;
    ctx.strokeRect(tx(0), ty(0), snap.boxSize * scale, snap.boxSize * scale);

    const ax = tx(snap.x);
    const ay = ty(snap.y);
    const agentR = 0.5 * scale;

    // sensor rays: faint teal (activity) normally, amber when the collision they just avoided/caused fires
    ctx.strokeStyle = snap.collided ? `${BRAND_COLORS.amber}cc` : `${BRAND_COLORS.tealSoft}88`;
    ctx.lineWidth = 1.5;
    for (const off of [Math.PI / 4, -Math.PI / 4]) {
      const a = snap.headingRad + off;
      ctx.beginPath();
      ctx.moveTo(ax, ay);
      ctx.lineTo(ax + Math.cos(a) * scale * 3, ay + Math.sin(a) * scale * 3);
      ctx.stroke();
    }

    // agent: teal (matches _draw_agent_boids! in the Makie extension); amber on collision (the amber "warn" semantic)
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
