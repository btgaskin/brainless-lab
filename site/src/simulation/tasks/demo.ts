import type { DemoTaskName, TaskEnv } from '../types';
import { PongEnv, type PongSnapshot } from './pong';
import { TrackingEnv, type TrackingSnapshot } from './tracking';
import { PlankCartPoleEnv, type PlankCartPoleSnapshot } from './cartpolePlank';

export type DemoTaskSnapshot =
  | { task: 'pong'; env: PongSnapshot }
  | { task: 'tracking'; env: TrackingSnapshot }
  | { task: 'cartpole_plank_easy'; env: PlankCartPoleSnapshot };

export interface DemoTaskDescriptor {
  name: DemoTaskName;
  label: string;
  createEnv: (seed: number) => TaskEnv;
}

export const DEMO_TASKS: Record<DemoTaskName, DemoTaskDescriptor> = {
  pong: { name: 'pong', label: 'Pong', createEnv: (seed) => new PongEnv(seed) },
  tracking: { name: 'tracking', label: 'Object tracking', createEnv: (seed) => new TrackingEnv(seed) },
  cartpole_plank_easy: {
    name: 'cartpole_plank_easy',
    label: 'CartPole Easy',
    createEnv: (seed) => new PlankCartPoleEnv('easy', seed),
  },
};

export function demoTaskSnapshot(task: DemoTaskName, env: TaskEnv): DemoTaskSnapshot {
  return { task, env: env.snapshot() } as DemoTaskSnapshot;
}
