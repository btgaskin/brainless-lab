import {
  DEFAULT_PARAMS,
  type CoreTaskName,
  type DemoTaskName,
  type FalandaysParams,
} from './types';

export interface CanonicalCoreCase {
  task: CoreTaskName;
  preset: `falandays_${CoreTaskName}`;
  horizon: number;
  warmup: number;
  benchmarkRootSeed: number;
  displayRootRange: readonly [number, number];
  params: FalandaysParams;
}

const sharedParams = {
  ...DEFAULT_PARAMS,
  leak: 0.25,
  lrateWmat: 1.0,
  thresholdMult: 2.0,
  targetFloor: 1.0,
  linkP: 0.1,
  rectify: false,
  learnWeights: true,
  learnTargets: true,
} satisfies FalandaysParams;

/**
 * Browser-facing copy of benchmarks/falandays-core/v2/benchmark.toml and the
 * three registered falandays_* compositions. Display roots are deliberately
 * disjoint from the planned benchmark roots.
 */
export const CANONICAL_CORE_V2: Record<CoreTaskName, CanonicalCoreCase> = {
  tracking: {
    task: 'tracking',
    preset: 'falandays_tracking',
    horizon: 7200,
    warmup: 1200,
    benchmarkRootSeed: 61001,
    displayRootRange: [71001, 71032],
    params: {
      ...sharedParams,
      N: 200,
      inputWeight: 0.75,
      lrateTarg: 0.01,
      weightInitMode: 'excitatory',
    },
  },
  pong: {
    task: 'pong',
    preset: 'falandays_pong',
    horizon: 7200,
    warmup: 1200,
    benchmarkRootSeed: 62001,
    displayRootRange: [72001, 72032],
    params: {
      ...sharedParams,
      N: 500,
      inputWeight: 2.75,
      lrateTarg: 0.1,
      weightInitMode: 'pongMixed',
    },
  },
  wall: {
    task: 'wall',
    preset: 'falandays_wall',
    horizon: 1000,
    warmup: 800,
    benchmarkRootSeed: 63001,
    displayRootRange: [73001, 73032],
    params: {
      ...sharedParams,
      N: 200,
      inputWeight: 4.0,
      lrateTarg: 0.01,
      weightInitMode: 'excitatory',
    },
  },
};

export const CORE_TASK_NAMES = ['pong', 'tracking', 'wall'] as const satisfies readonly CoreTaskName[];

/** Landing tasks: two established cases and one experimental capacity challenge. */
export const DEMO_TASK_NAMES = [
  'pong',
  'tracking',
  'cartpole_plank_easy',
] as const satisfies readonly DemoTaskName[];

export function canonicalParamsFor(task: CoreTaskName): FalandaysParams {
  return { ...CANONICAL_CORE_V2[task].params };
}

export function displayRootCandidates(task: CoreTaskName): number[] {
  const [first, last] = CANONICAL_CORE_V2[task].displayRootRange;
  return Array.from({ length: last - first + 1 }, (_, index) => first + index);
}
