import type { PlankCartPoleTaskName, TaskEnv, TaskName } from '../types';
import { WallEnv, type WallSnapshot } from './wall';
import { TrackingEnv, type TrackingSnapshot } from './tracking';
import { PongEnv, type PongSnapshot } from './pong';
import {
  plankCartPoleLevel,
  PlankCartPoleEnv,
  type PlankCartPoleSnapshot,
} from './cartpolePlank';

export type { WallSnapshot, TrackingSnapshot, PongSnapshot, PlankCartPoleSnapshot };
export { WallEnv, TrackingEnv, PongEnv, PlankCartPoleEnv };

export interface TaskDescriptor {
  name: TaskName;
  label: string;
  createEnv: (seed: number) => TaskEnv;
}

function plankTask(name: PlankCartPoleTaskName): TaskDescriptor {
  const level = plankCartPoleLevel(name);
  return {
    name,
    label: `Plank · ${level.label}`,
    createEnv: (seed) => new PlankCartPoleEnv(level.name, seed),
  };
}

export const TASKS: Record<TaskName, TaskDescriptor> = {
  pong: { name: 'pong', label: 'Pong', createEnv: (seed) => new PongEnv(seed) },
  tracking: { name: 'tracking', label: 'Object tracking', createEnv: () => new TrackingEnv() },
  wall: { name: 'wall', label: 'Wall avoidance', createEnv: (seed) => new WallEnv(seed) },
  cartpole_plank_easy: plankTask('cartpole_plank_easy'),
  cartpole_plank_medium: plankTask('cartpole_plank_medium'),
  cartpole_plank_hard: plankTask('cartpole_plank_hard'),
  cartpole_plank_hardest: plankTask('cartpole_plank_hardest'),
};

export const TASK_NAMES: TaskName[] = [
  'pong',
  'tracking',
  'wall',
  'cartpole_plank_easy',
  'cartpole_plank_medium',
  'cartpole_plank_hard',
  'cartpole_plank_hardest',
];
