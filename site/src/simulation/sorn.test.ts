import { describe, expect, test } from 'bun:test';
import { SornReservoir } from './sorn';
import { DEFAULT_SORN_PARAMS } from './types';

const INPUTS = [
  [0.2, 0.8],
  [0.7, 0.1],
  [0.4, 0.4],
  [0.9, 0.2],
] as const;

describe('browser SORN reservoir', () => {
  test('counts both populations in N and returns independently owned spikes', () => {
    const reservoir = new SornReservoir(2, 2, { ...DEFAULT_SORN_PARAMS, N: 200 }, 17);
    expect(reservoir.nExcitatory).toBe(167);
    expect(reservoir.nInhibitory).toBe(33);
    const spikes = reservoir.step(INPUTS[0]);
    const saved = Array.from(spikes);
    expect(spikes.length).toBe(200);
    reservoir.step(INPUTS[1]);
    expect(Array.from(spikes)).toEqual(saved);
  });

  test('permanently prunes synapses depressed to zero', () => {
    const reservoir = new SornReservoir(2, 2, { ...DEFAULT_SORN_PARAMS, N: 40, etaStdp: 2 }, 17);
    const initial = reservoir.stateFingerprint()[5];
    let previous = initial;
    for (let step = 0; step < 100; step++) {
      reservoir.step(INPUTS[step % INPUTS.length]);
      const remaining = reservoir.stateFingerprint()[5];
      expect(remaining).toBeLessThanOrEqual(previous);
      previous = remaining;
    }
    expect(previous).toBeLessThan(initial);
  });

  test('is deterministic for a fixed topology seed and receptor sequence', () => {
    const first = new SornReservoir(2, 2, { ...DEFAULT_SORN_PARAMS, N: 40 }, 17);
    const second = new SornReservoir(2, 2, { ...DEFAULT_SORN_PARAMS, N: 40 }, 17);

    for (let step = 0; step < 40; step++) {
      const input = INPUTS[step % INPUTS.length];
      expect(Array.from(first.step(input))).toEqual(Array.from(second.step(input)));
      expect(first.effectorOutputs()).toEqual(second.effectorOutputs());
    }
    expect(first.stateFingerprint()).toEqual(second.stateFingerprint());
  });

  test('freezes STDP, intrinsic plasticity, and normalisation together', () => {
    const reservoir = new SornReservoir(
      2,
      2,
      { ...DEFAULT_SORN_PARAMS, N: 40, learnOn: false },
      23,
    );
    const before = reservoir.stateFingerprint().slice(3);
    for (let step = 0; step < 20; step++) reservoir.step(INPUTS[step % INPUTS.length]);
    expect(reservoir.stateFingerprint().slice(3)).toEqual(before);
    expect(reservoir.currentTick).toBe(20);
  });
});
