import type { TaskEnv, TaskName } from '../types';
import { WallEnv, type WallSnapshot } from './wall';
import { TrackingEnv, type TrackingSnapshot } from './tracking';
import { PongEnv, type PongSnapshot } from './pong';

export type { WallSnapshot, TrackingSnapshot, PongSnapshot };
export { WallEnv, TrackingEnv, PongEnv };

export interface TaskDescriptor {
  name: TaskName;
  label: string;
  createEnv: (seed: number) => TaskEnv;
}

export const TASKS: Record<TaskName, TaskDescriptor> = {
  wall: { name: 'wall', label: 'Wall avoidance', createEnv: (seed) => new WallEnv(seed) },
  tracking: { name: 'tracking', label: 'Object tracking', createEnv: () => new TrackingEnv() },
  pong: { name: 'pong', label: 'Pong', createEnv: (seed) => new PongEnv(seed) },
};

export const TASK_NAMES: TaskName[] = ['wall', 'tracking', 'pong'];
