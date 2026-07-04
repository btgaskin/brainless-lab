import type { PongSnapshot } from '../../../simulation/tasks/pong';
import type { Renderer } from './types';
import { BRAND_COLORS } from './types';

export class PongRenderer implements Renderer<PongSnapshot> {
  draw(ctx: CanvasRenderingContext2D, snap: PongSnapshot): void {
    const { width, height } = ctx.canvas;
    const scale = Math.min(width / snap.arenaW, height / snap.arenaH) * 0.92;
    const ox = (width - snap.arenaW * scale) / 2;
    const oy = (height - snap.arenaH * scale) / 2;
    const tx = (v: number) => ox + v * scale;
    const ty = (v: number) => oy + v * scale;

    ctx.clearRect(0, 0, width, height);
    ctx.fillStyle = BRAND_COLORS.paper;
    ctx.fillRect(0, 0, width, height);
    ctx.strokeStyle = BRAND_COLORS.grid;
    ctx.lineWidth = 1.5;
    ctx.strokeRect(tx(0), ty(0), snap.arenaW * scale, snap.arenaH * scale);

    // paddle: teal (agent semantic)
    ctx.fillStyle = BRAND_COLORS.teal;
    ctx.fillRect(tx(snap.paddleX) - 4, ty(snap.paddleY), 6, snap.paddleH * scale);

    // ball: amber (stimulus/target semantic)
    ctx.beginPath();
    ctx.arc(tx(snap.ballX), ty(snap.ballY), snap.ballR * scale, 0, Math.PI * 2);
    ctx.fillStyle = BRAND_COLORS.amber;
    ctx.fill();
  }
}
