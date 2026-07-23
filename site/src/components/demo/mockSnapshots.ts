/**
 * Deterministic, pre-computed task-world snapshots for Storybook stories —
 * built by actually running the real (already-tested) simulation module for
 * a fixed number of ticks at a fixed seed, not hand-authored fake data.
 */
import { WallEnv } from '../../simulation/tasks/wall';
import { TrackingEnv } from '../../simulation/tasks/tracking';
import { PongEnv } from '../../simulation/tasks/pong';
import {
  PlankCartPoleEnv,
  type PlankCartPoleLevelName,
} from '../../simulation/tasks/cartpolePlank';

export function runWall(steps: number, seed = 1) {
  const env = new WallEnv(seed);
  for (let i = 0; i < steps; i++) env.step([0.9, 0.6]);
  return env.snapshot();
}

export function runTracking(steps: number) {
  const env = new TrackingEnv();
  for (let i = 0; i < steps; i++) env.step([0.7, 0.3]);
  return env.snapshot();
}

export function runPong(steps: number, seed = 2) {
  const env = new PongEnv(seed);
  for (let i = 0; i < steps; i++) env.step([0.5, 0.5]);
  return env.snapshot();
}

export function runCartPole(level: PlankCartPoleLevelName, steps: number, seed = 3) {
  const env = new PlankCartPoleEnv(level, seed);
  for (let i = 0; i < steps && !env.snapshot().done; i++) {
    const action = new Array<number>(env.nEffectors).fill(0);
    const offset = env.nEffectors === 3 ? 1 : 0;
    action[offset + (i % 2)] = 1;
    env.step(action);
  }
  return env.snapshot();
}
