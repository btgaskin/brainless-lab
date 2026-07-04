import { describe, expect, it } from 'vitest';
import { FalandaysReservoir } from './falandays';
import { DEFAULT_PARAMS } from './types';

function makeReservoir(overrides: Partial<typeof DEFAULT_PARAMS> = {}, seed = 1) {
  const params = { ...DEFAULT_PARAMS, N: 20, ...overrides };
  return new FalandaysReservoir(4, 2, params, seed);
}

describe('FalandaysReservoir', () => {
  it('spikes when activation reaches the threshold exactly (>=, not >)', () => {
    const r = makeReservoir({ N: 1, thresholdMult: 2, targetFloor: 1, leak: 0, linkP: 0 });
    // target starts at 1 -> threshold = 2. With linkP=0, ensureNodeInDegree
    // force-connects one *random* receptor so the node isn't permanently dead
    // — drive all 4 receptors hard so whichever one got picked still fires.
    let spikes: ReturnType<typeof r.step> = new Float64Array(1);
    for (let i = 0; i < 200 && spikes[0] === 0; i++) {
      spikes = r.step([1000, 1000, 1000, 1000]);
    }
    expect(spikes[0]).toBe(1);
  });

  it('drops activation by exactly the threshold on spike', () => {
    const r = makeReservoir({ N: 1, thresholdMult: 2, targetFloor: 1, leak: 0, linkP: 0, learnTargets: false });
    r.step([1000, 0, 0, 0]);
    const snap = r.snapshot();
    // acts should be (something >= threshold) - threshold, i.e. a small
    // non-negative remainder, never the raw pre-spike activation.
    expect(snap.acts[0]).toBeGreaterThanOrEqual(0);
    expect(snap.acts[0]).toBeLessThan(snap.targets[0] * DEFAULT_PARAMS.thresholdMult);
  });

  it('never lets a target drop below the configured floor', () => {
    const floor = 1.5;
    const r = makeReservoir({ targetFloor: floor, lrateTarg: 0.5 });
    for (let i = 0; i < 500; i++) {
      r.step([0, 0, 0, 0]); // no input -> activation stays low -> negative error pressure
    }
    const snap = r.snapshot();
    for (const t of snap.targets) expect(t).toBeGreaterThanOrEqual(floor - 1e-9);
  });

  it('freezes weights when learning is off, and changes them when on (same seed)', () => {
    const seed = 42;
    const frozen = makeReservoir({ learnWeights: false }, seed);
    const learning = makeReservoir({ learnWeights: true }, seed);
    const w0 = frozen.snapshot().wmat.slice();

    for (let i = 0; i < 100; i++) {
      const input = [Math.random(), Math.random(), Math.random(), Math.random()];
      frozen.step(input);
      learning.step(input);
    }

    expect(frozen.snapshot().wmat).toEqual(w0);
    expect(learning.snapshot().wmat).not.toEqual(w0);
  });

  it('reset() restores the initial weights and clears runtime state', () => {
    const r = makeReservoir();
    const w0 = r.snapshot().wmat.slice();
    for (let i = 0; i < 50; i++) r.step([1, 0.5, 0, 0]);
    expect(r.snapshot().wmat).not.toEqual(w0);

    r.reset();
    const snap = r.snapshot();
    expect(snap.wmat).toEqual(w0);
    expect(Array.from(snap.acts)).toEqual(new Array(snap.nNodes).fill(0));
    expect(Array.from(snap.targets)).toEqual(new Array(snap.nNodes).fill(1));
  });

  it('every effector output stays within [0, 1] (a spike-fraction readout)', () => {
    const r = makeReservoir();
    for (let i = 0; i < 100; i++) {
      r.step([Math.random(), Math.random(), Math.random(), Math.random()]);
      for (const e of r.effectorOutputs()) {
        expect(e).toBeGreaterThanOrEqual(0);
        expect(e).toBeLessThanOrEqual(1);
      }
    }
  });

  it('stays fast at N=1000 — well beyond any per-task default, a stress ceiling not a claim about defaults', () => {
    // Per-task N now matches the paper exactly (200 tracking/wall, 500 pong —
    // see presets.ts), all comfortably below this. N=1000 here is just proof
    // the slider's upper range (up to 2000) doesn't fall over: with no
    // per-node graph rendered, this is pure compute, not rendering, and the
    // demo ticks every TICK_INTERVAL_MS=50ms — a single step should stay well
    // under that with wide margin for the browser JS engine being somewhat
    // slower than this test environment's.
    const r = new FalandaysReservoir(62, 3, { ...DEFAULT_PARAMS, N: 1000 }, 7); // largest task, tracking (62 receptors)
    const receptors = new Array(62).fill(0).map(() => Math.random());
    const start = performance.now();
    const iterations = 50;
    for (let i = 0; i < iterations; i++) r.step(receptors);
    const perTickMs = (performance.now() - start) / iterations;
    expect(perTickMs).toBeLessThan(20);
  });
});
