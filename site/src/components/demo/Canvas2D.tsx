import { useCallback, useEffect, useRef } from 'react';
import type { Renderer } from './renderers/types';

interface Canvas2DProps<Snap> {
  renderer: Renderer<Snap>;
  snapshot: Snap;
  className?: string;
}

/**
 * Prop-driven canvas: redraws whenever `snapshot` changes or the parent
 * resizes. This is the mock-data / low-frequency-update path used by stories
 * and (for now) SimDemo's setInterval ticker. The eventual live 60fps path
 * (useSimLoop, task 5 of the build plan) bypasses this component's render
 * cycle entirely and draws imperatively from a rAF loop — see the plan's
 * "why it won't jank" note. No React state ever holds per-tick sim data here.
 */
export function Canvas2D<Snap>({ renderer, snapshot, className }: Canvas2DProps<Snap>) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const rendererRef = useRef(renderer);
  const snapshotRef = useRef(snapshot);
  rendererRef.current = renderer;
  snapshotRef.current = snapshot;

  const redraw = useCallback(() => {
    const ctx = canvasRef.current?.getContext('2d');
    if (!ctx) return;
    rendererRef.current.draw(ctx, snapshotRef.current);
  }, []);

  useEffect(() => {
    const canvas = canvasRef.current;
    const parent = canvas?.parentElement;
    if (!canvas || !parent) return;

    const resize = () => {
      const w = parent.clientWidth;
      const h = parent.clientHeight;
      if (w === 0 || h === 0) return;
      canvas.width = w;
      canvas.height = h;
      rendererRef.current.resize?.(w, h);
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
