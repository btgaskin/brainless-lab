import { describe, expect, test } from 'bun:test';
import { CANONICAL_CORE_V2, CORE_TASK_NAMES, canonicalParamsFor, displayRootCandidates } from './canonical';
import { createCoreSimulation, runCoreTicks } from './coreRuntime';
import { DISPLAY_CASES } from './displayCases';
import { derivePortSeed } from './rng';

describe('canonical core v2 browser contract', () => {
  test('matches the registered composition and evaluation values', () => {
    expect(CANONICAL_CORE_V2.pong).toMatchObject({
      preset: 'falandays_pong',
      horizon: 7200,
      warmup: 1200,
      benchmarkRootSeed: 62001,
      params: { N: 500, inputWeight: 2.75, lrateWmat: 1, lrateTarg: 0.1, weightInitMode: 'pongMixed' },
    });
    expect(CANONICAL_CORE_V2.tracking).toMatchObject({
      preset: 'falandays_tracking',
      horizon: 7200,
      warmup: 1200,
      benchmarkRootSeed: 61001,
      params: { N: 200, inputWeight: 0.75, lrateWmat: 1, lrateTarg: 0.01, weightInitMode: 'excitatory' },
    });
    expect(CANONICAL_CORE_V2.wall).toMatchObject({
      preset: 'falandays_wall',
      horizon: 1000,
      warmup: 800,
      benchmarkRootSeed: 63001,
      params: { N: 200, inputWeight: 4, lrateWmat: 1, lrateTarg: 0.01, weightInitMode: 'excitatory' },
    });
    for (const task of CORE_TASK_NAMES) {
      expect(CANONICAL_CORE_V2[task].params).toMatchObject({
        leak: 0.25,
        thresholdMult: 2,
        targetFloor: 1,
        linkP: 0.1,
        rectify: false,
        learnWeights: true,
        learnTargets: true,
      });
    }
  });

  test('keeps display roots outside the planned benchmark roots', () => {
    const benchmarkRoots = new Set(CORE_TASK_NAMES.map((task) => CANONICAL_CORE_V2[task].benchmarkRootSeed));
    for (const task of CORE_TASK_NAMES) {
      const candidates = displayRootCandidates(task);
      expect(candidates).toHaveLength(32);
      expect(candidates).not.toContain(CANONICAL_CORE_V2[task].benchmarkRootSeed);
      expect(benchmarkRoots.has(DISPLAY_CASES[task].rootSeed)).toBe(false);
      expect(candidates).toContain(DISPLAY_CASES[task].rootSeed);
      expect(DISPLAY_CASES[task].quantile).toBe(0.7);
    }
  });

  test('derives stable, separate topology and world streams', () => {
    const topology = derivePortSeed(72006, 'topology', 1, 1, 1);
    const world = derivePortSeed(72006, 'world', 1, 1);
    expect(topology).toBe(derivePortSeed(72006, 'topology', 1, 1, 1));
    expect(world).toBe(derivePortSeed(72006, 'world', 1, 1));
    expect(topology).not.toBe(world);
  });

  test('reconstructs the same display world from the same root', () => {
    const first = createCoreSimulation('wall', canonicalParamsFor('wall'), DISPLAY_CASES.wall.rootSeed);
    const second = createCoreSimulation('wall', canonicalParamsFor('wall'), DISPLAY_CASES.wall.rootSeed);
    runCoreTicks(first, 40);
    runCoreTicks(second, 40);
    expect(first.reservoir.currentTick).toBe(40);
    expect(first.env.snapshot()).toEqual(second.env.snapshot());
  });
});
