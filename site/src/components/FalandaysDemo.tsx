import { useEffect, useRef, useState } from 'react';

/**
 * Interactive Falandays demo — Astro React island.
 *
 * SCAFFOLD PLACEHOLDER. The real, in-browser Falandays simulation already exists
 * in `website/src/` (the `simulation/` TS port + `components/demo`). To wire it in,
 * either (a) move `website/src/simulation` + `website/src/components/demo` under
 * `site/src/`, or (b) set up a bun workspace so this island can
 * `import { FalandaysDemo } from '@brainlesslab/demo'`. Until then this renders a
 * lightweight brand-styled preview so the island + palette are visible.
 */
export default function FalandaysDemo() {
  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  const [running, setRunning] = useState(true);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext('2d');
    if (!ctx) return;

    const N = 28;
    const dots = Array.from({ length: N }, (_, i) => ({
      x: Math.random(),
      y: Math.random(),
      phase: (i / N) * Math.PI * 2,
    }));
    let raf = 0;
    let t = 0;

    const draw = () => {
      const w = canvas.width;
      const h = canvas.height;
      ctx.fillStyle = '#fbfaf7';
      ctx.fillRect(0, 0, w, h);
      for (const d of dots) {
        const fire = Math.sin(t * 0.05 + d.phase) > 0.4;
        ctx.beginPath();
        ctx.arc(d.x * w, d.y * h, fire ? 5 : 3, 0, Math.PI * 2);
        ctx.fillStyle = fire ? '#2f6f5e' : '#dedad0';
        ctx.fill();
      }
      t += 1;
      if (running) raf = requestAnimationFrame(draw);
    };
    draw();
    return () => cancelAnimationFrame(raf);
  }, [running]);

  return (
    <figure style={{ margin: 0 }}>
      <canvas
        ref={canvasRef}
        width={640}
        height={280}
        style={{ width: '100%', borderRadius: 10, border: '1px solid #dedad0' }}
      />
      <figcaption style={{ display: 'flex', gap: '0.75rem', alignItems: 'center', marginTop: '0.6rem' }}>
        <button onClick={() => setRunning((r) => !r)} style={{ padding: '0.3rem 0.8rem' }}>
          {running ? 'Pause' : 'Play'}
        </button>
        <span style={{ color: '#52585d', fontSize: '0.85em' }}>
          Preview — the live Falandays sim from <code>website/</code> mounts here.
        </span>
      </figcaption>
    </figure>
  );
}
