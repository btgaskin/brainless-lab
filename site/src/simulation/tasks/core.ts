import type { CoreTaskName, TaskEnv } from '../types';
import { PongEnv, type PongSnapshot } from './pong';
import { TrackingEnv, type TrackingSnapshot } from './tracking';
import { WallEnv, type WallSnapshot } from './wall';

export type CoreTaskSnapshot =
  | { task: 'pong'; env: PongSnapshot }
  | { task: 'tracking'; env: TrackingSnapshot }
  | { task: 'wall'; env: WallSnapshot };

export interface CoreTaskDescriptor {
  name: CoreTaskName;
  label: string;
  createEnv: (seed: number) => TaskEnv;
}

export const CORE_TASKS: Record<CoreTaskName, CoreTaskDescriptor> = {
  pong: { name: 'pong', label: 'Pong', createEnv: (seed) => new PongEnv(seed) },
  tracking: { name: 'tracking', label: 'Object tracking', createEnv: (seed) => new TrackingEnv(seed) },
  wall: { name: 'wall', label: 'Wall avoidance', createEnv: (seed) => new WallEnv(seed) },
};

export function coreTaskSnapshot(task: CoreTaskName, env: TaskEnv): CoreTaskSnapshot {
  return { task, env: env.snapshot() } as CoreTaskSnapshot;
}
