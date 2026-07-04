import { useCallback, useEffect, useRef } from 'react';
import type { Renderer } from './renderers/types';

interface Canvas2DProps<Snap> {
  renderer: Renderer<Snap>;
  snapshot: Snap;
  className?: string;
}

/**
 * Prop-driven canvas: redraws whenever `snapshot` changes or the parent
 * resizes. Backing-store size is clientSize x devicePixelRatio with the DPR
 * transform pre-applied, so renderers draw in logical (CSS-pixel) coordinates
 * and stay crisp on retina displays. This is the low-frequency-update path
 * used by SimDemo's setInterval ticker; a future 60fps path (useSimLoop)
 * would bypass the React render cycle and draw imperatively from rAF.
 * No React state ever holds per-tick sim data here.
 */
export function Canvas2D<Snap>({ renderer, snapshot, className }: Canvas2DProps<Snap>) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const rendererRef = useRef(renderer);
  const snapshotRef = useRef(snapshot);
  const sizeRef = useRef({ w: 0, h: 0, dpr: 1 });
  rendererRef.current = renderer;
  snapshotRef.current = snapshot;

  const redraw = useCallback(() => {
    const ctx = canvasRef.current?.getContext('2d');
    if (!ctx) return;
    const { w, h, dpr } = sizeRef.current;
    if (w === 0 || h === 0) return;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, w, h);

    // Normalize every task to roughly the same footprint (equal area), centered in
    // the shared frame, so switching tasks doesn't jump the arena size. `aspect`
    // is the world's w:h; the transparent margins show the frame's card background.
    const aspect = rendererRef.current.aspect || 1;
    const ref = 0.94 * Math.min(w, h);
    let bw = ref * Math.sqrt(aspect);
    let bh = ref / Math.sqrt(aspect);
    const fit = Math.min(1, (w * 0.98) / bw, (h * 0.98) / bh);
    bw *= fit;
    bh *= fit;

    ctx.translate((w - bw) / 2, (h - bh) / 2);
    rendererRef.current.draw(ctx, snapshotRef.current, bw, bh);
  }, []);

  useEffect(() => {
    const canvas = canvasRef.current;
    const parent = canvas?.parentElement;
    if (!canvas || !parent) return;

    const resize = () => {
      const w = parent.clientWidth;
      const h = parent.clientHeight;
      if (w === 0 || h === 0) return;
      const dpr = window.devicePixelRatio || 1;
      canvas.width = Math.round(w * dpr);
      canvas.height = Math.round(h * dpr);
      sizeRef.current = { w, h, dpr };
      redraw();
    };

    resize();
    const ro = new ResizeObserver(resize);
    ro.observe(parent);
    return () => ro.disconnect();
  }, [redraw]);

  useEffect(() => {
    redraw();
  }, [snapshot, redraw]);

  return <canvas ref={canvasRef} className={className ?? 'block h-full w-full'} />;
}
