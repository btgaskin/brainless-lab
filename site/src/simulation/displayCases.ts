import type { CoreTaskName } from './types';

export interface DisplayCaseSelection {
  rootSeed: number;
  outcomeKey: string;
  rawOutcome: number;
  candidateCount: number;
  quantile: number;
  topologySeed: number;
  worldSeed: number;
}

/** Development-only display roots. These are not benchmark trials or evidence. */
export const DISPLAY_CASES: Record<CoreTaskName, DisplayCaseSelection> = {
  pong: {
    rootSeed: 72006,
    outcomeKey: 'hit_rate',
    rawOutcome: 0.8333333333333334,
    candidateCount: 32,
    quantile: 0.7,
    topologySeed: 1366297718,
    worldSeed: 2961992845,
  },
  tracking: {
    rootSeed: 71006,
    outcomeKey: 'track_score',
    rawOutcome: 0.3538725989626606,
    candidateCount: 32,
    quantile: 0.7,
    topologySeed: 942669309,
    worldSeed: 1455096668,
  },
  wall: {
    rootSeed: 73020,
    outcomeKey: 'nav_score',
    rawOutcome: 1,
    candidateCount: 32,
    quantile: 0.7,
    topologySeed: 1979140871,
    worldSeed: 4241318934,
  },
};
