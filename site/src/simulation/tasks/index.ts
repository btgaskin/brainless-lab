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
  pong: { name: 'pong', label: 'Pong', createEnv: (seed) => new PongEnv(seed) },
  tracking: { name: 'tracking', label: 'Object tracking', createEnv: () => new TrackingEnv() },
  wall: { name: 'wall', label: 'Wall avoidance', createEnv: (seed) => new WallEnv(seed) },
};

export const TASK_NAMES: TaskName[] = ['pong', 'tracking', 'wall'];
