import { Rng } from '../rng';
import type { PlankCartPoleTaskName, TaskEnv } from '../types';

export type PlankCartPoleLevelName = 'easy' | 'medium' | 'hard' | 'hardest';
export type PlankCartPoleAction = 'noop' | 'left' | 'right';
export type PlankCartPoleEncoder = 'spike_ff_2' | 'argyle_4';

export interface PlankCartPoleLevel {
  task: PlankCartPoleTaskName;
  name: PlankCartPoleLevelName;
  label: string;
  observationIndices: readonly number[];
  observationLabel: string;
  actions: readonly PlankCartPoleAction[];
  encoder: PlankCartPoleEncoder;
  targetFitness: number;
  activityThreshold: number | null;
}

const MISSION_STEPS = 15_000;
const NEURAL_FRAMES = 24;
const OBSERVATION_SCALES = [2.4, 2.0, 0.2095, 2.0] as const;
const INITIAL_RANGES = [
  [-1.2, 1.2],
  [-0.05, 0.05],
  [-0.10475, 0.10475],
  [-0.05, 0.05],
] as const;
const ARGYLE_FRAME_SCHEDULE = [0, 3, 6, 9, 12, 14, 17, 20, 23] as const;

const TAU = 0.02;
const GRAVITY = 9.8;
const FORCE_MAG = 10;
const POLE_HALF_LENGTH = 0.5;
const POLE_MASS = 0.1;
const TOTAL_MASS = 1.1;
const MAX_X = 2.4;
const MAX_THETA = 0.2095;

export const PLANK_CARTPOLE_LEVELS: Record<PlankCartPoleLevelName, PlankCartPoleLevel> = {
  easy: {
    task: 'cartpole_plank_easy',
    name: 'easy',
    label: 'Easy',
    observationIndices: [0, 1, 2, 3],
    observationLabel: 'x · ẋ · θ · θ̇',
    actions: ['left', 'right'],
    encoder: 'spike_ff_2',
    targetFitness: 14_250,
    activityThreshold: null,
  },
  medium: {
    task: 'cartpole_plank_medium',
    name: 'medium',
    label: 'Medium',
    observationIndices: [0, 1, 2, 3],
    observationLabel: 'x · ẋ · θ · θ̇',
    actions: ['noop', 'left', 'right'],
    encoder: 'spike_ff_2',
    targetFitness: 12_000,
    activityThreshold: 0.75,
  },
  hard: {
    task: 'cartpole_plank_hard',
    name: 'hard',
    label: 'Hard',
    observationIndices: [0, 2],
    observationLabel: 'x · θ',
    actions: ['noop', 'left', 'right'],
    encoder: 'spike_ff_2',
    targetFitness: 9_000,
    activityThreshold: null,
  },
  hardest: {
    task: 'cartpole_plank_hardest',
    name: 'hardest',
    label: 'Hardest',
    observationIndices: [0, 2],
    observationLabel: 'x · θ',
    actions: ['left', 'right'],
    encoder: 'argyle_4',
    targetFitness: 6_000,
    activityThreshold: null,
  },
};

export const PLANK_CARTPOLE_TASKS = Object.values(PLANK_CARTPOLE_LEVELS).map((level) => level.task);

const LEVEL_BY_TASK = Object.fromEntries(
  Object.values(PLANK_CARTPOLE_LEVELS).map((level) => [level.task, level]),
) as Record<PlankCartPoleTaskName, PlankCartPoleLevel>;

export function plankCartPoleLevel(task: PlankCartPoleTaskName): PlankCartPoleLevel {
  return LEVEL_BY_TASK[task];
}

export function isPlankCartPoleTask(task: string): task is PlankCartPoleTaskName {
  return task in LEVEL_BY_TASK;
}

export interface PlankCartPoleSnapshot {
  level: PlankCartPoleLevelName;
  levelLabel: string;
  observationLabel: string;
  actionCount: number;
  encoder: PlankCartPoleEncoder;
  x: number;
  xDot: number;
  theta: number;
  thetaDot: number;
  maxX: number;
  maxTheta: number;
  poleLength: number;
  stepCount: number;
  missionSteps: number;
  noopFraction: number;
  targetFitness: number;
  fitness: number;
  done: boolean;
  lastAction: PlankCartPoleAction | null;
}

/**
 * The four experimental Plank profiles share one Gym-style CartPole world.
 * A level descriptor freezes the observation subset, temporal encoder, action
 * vocabulary, and Medium no-op fitness rule.
 */
export class PlankCartPoleEnv implements TaskEnv<PlankCartPoleSnapshot> {
  readonly neuralFrames = NEURAL_FRAMES;
  readonly nReceptors: number;
  readonly nEffectors: number;

  readonly level: PlankCartPoleLevel;
  private readonly rng: Rng;
  private state = new Float64Array(4);
  private stepCount = 0;
  private noopCount = 0;
  private done = false;
  private lastAction: PlankCartPoleAction | null = null;

  constructor(level: PlankCartPoleLevelName | PlankCartPoleTaskName, seed = 0) {
    this.level = isPlankCartPoleTask(level) ? plankCartPoleLevel(level) : PLANK_CARTPOLE_LEVELS[level];
    this.nReceptors =
      this.level.observationIndices.length * (this.level.encoder === 'argyle_4' ? 4 : 2);
    this.nEffectors = this.level.actions.length;
    this.rng = new Rng(seed);
    this.randomizeState();
  }

  reset(): void {
    this.randomizeState();
    this.stepCount = 0;
    this.noopCount = 0;
    this.done = false;
    this.lastAction = null;
  }

  sense(): Float64Array {
    return this.senseFrame(0);
  }

  senseFrame(frame: number): Float64Array {
    const out = new Float64Array(this.nReceptors);
    if (this.done) return out;
    return this.level.encoder === 'argyle_4'
      ? this.encodeArgyleFrame(frame, out)
      : this.encodeSpikeFf2Frame(frame, out);
  }

  reduceEffectors(frames: readonly number[][]): number[] {
    const votes = new Array<number>(this.nEffectors).fill(0);
    for (const outputs of frames) votes[firstMaximum(outputs, this.nEffectors, true)] += 1;
    const winner = firstMaximum(votes, this.nEffectors);
    return votes.map((_, index) => (index === winner ? 1 : 0));
  }

  isTerminal(): boolean {
    return this.done;
  }

  step(effectors: number[]): void {
    if (this.done) return;

    const winner = firstMaximum(effectors, this.nEffectors, true);
    const action = this.level.actions[winner];
    this.lastAction = action;
    if (action === 'noop') this.noopCount += 1;
    const force = action === 'left' ? -FORCE_MAG : action === 'right' ? FORCE_MAG : 0;
    this.integrateExplicitEuler(force);

    this.stepCount += 1;
    this.done =
      Math.abs(this.state[0]) > MAX_X ||
      Math.abs(this.state[2]) > MAX_THETA ||
      this.stepCount >= MISSION_STEPS;
  }

  snapshot(): PlankCartPoleSnapshot {
    return {
      level: this.level.name,
      levelLabel: this.level.label,
      observationLabel: this.level.observationLabel,
      actionCount: this.level.actions.length,
      encoder: this.level.encoder,
      x: this.state[0],
      xDot: this.state[1],
      theta: this.state[2],
      thetaDot: this.state[3],
      maxX: MAX_X,
      maxTheta: MAX_THETA,
      poleLength: 2 * POLE_HALF_LENGTH,
      stepCount: this.stepCount,
      missionSteps: MISSION_STEPS,
      noopFraction: this.stepCount === 0 ? 0 : this.noopCount / this.stepCount,
      targetFitness: this.level.targetFitness,
      fitness: this.fitness(),
      done: this.done,
      lastAction: this.lastAction,
    };
  }

  private encodeSpikeFf2Frame(frame: number, out: Float64Array): Float64Array {
    if (frame < 0 || frame >= NEURAL_FRAMES || frame % 3 !== 0) return out;
    const slot = frame / 3 + 1;
    for (let observation = 0; observation < this.level.observationIndices.length; observation++) {
      const stateIndex = this.level.observationIndices[observation];
      const value = this.state[stateIndex];
      const count = clamp(Math.ceil((8 * Math.abs(value)) / OBSERVATION_SCALES[stateIndex]), 0, 8);
      if (slot <= count) out[2 * observation + (value <= 0 ? 0 : 1)] = 1;
    }
    return out;
  }

  private encodeArgyleFrame(frame: number, out: Float64Array): Float64Array {
    const scheduleIndex = ARGYLE_FRAME_SCHEDULE.indexOf(frame as (typeof ARGYLE_FRAME_SCHEDULE)[number]);
    if (scheduleIndex < 0) return out;
    const slot = scheduleIndex + 1;

    for (let observation = 0; observation < this.level.observationIndices.length; observation++) {
      const stateIndex = this.level.observationIndices[observation];
      const scale = OBSERVATION_SCALES[stateIndex];
      const p = clamp((this.state[stateIndex] + scale) / (2 * scale), 0, 1);
      const position = 3 * p;
      const lower = Math.floor(position);
      const firstBin = Math.min(lower, 3);
      const secondBin = Math.min(firstBin + 1, 3);
      const secondCount = firstBin === secondBin ? 0 : roundTiesToEven(9 * (position - lower));
      const firstCount = 9 - secondCount;
      if (slot <= firstCount) out[4 * observation + firstBin] = 1;
      if (slot <= secondCount) out[4 * observation + secondBin] = 1;
    }
    return out;
  }

  private integrateExplicitEuler(force: number): void {
    const [x, xDot, theta, thetaDot] = this.state;
    const cosTheta = Math.cos(theta);
    const sinTheta = Math.sin(theta);
    const temp = (force + POLE_MASS * POLE_HALF_LENGTH * thetaDot ** 2 * sinTheta) / TOTAL_MASS;
    const thetaAcc =
      (GRAVITY * sinTheta - cosTheta * temp) /
      (POLE_HALF_LENGTH * (4 / 3 - (POLE_MASS * cosTheta ** 2) / TOTAL_MASS));
    const xAcc = temp - (POLE_MASS * POLE_HALF_LENGTH * thetaAcc * cosTheta) / TOTAL_MASS;

    this.state[0] = x + TAU * xDot;
    this.state[1] = xDot + TAU * xAcc;
    this.state[2] = theta + TAU * thetaDot;
    this.state[3] = thetaDot + TAU * thetaAcc;
  }

  private fitness(): number {
    if (this.level.activityThreshold === null) return this.stepCount;
    if (this.stepCount === 0) return 0;
    const noopFraction = this.noopCount / this.stepCount;
    return noopFraction > this.level.activityThreshold
      ? this.stepCount
      : this.noopCount / this.level.activityThreshold;
  }

  private randomizeState(): void {
    for (let index = 0; index < INITIAL_RANGES.length; index++) {
      const [lo, hi] = INITIAL_RANGES[index];
      this.state[index] = lo + this.rng.uniform() * (hi - lo);
    }
  }
}

function firstMaximum(values: ArrayLike<number>, width: number, bounded = false): number {
  let winner = 0;
  let maximum = Number.NEGATIVE_INFINITY;
  for (let index = 0; index < width; index++) {
    const raw = Number(values[index] ?? 0);
    const value = bounded ? clamp(raw, 0, 1) : raw;
    if (value > maximum) {
      maximum = value;
      winner = index;
    }
  }
  return winner;
}

function roundTiesToEven(value: number): number {
  const floor = Math.floor(value);
  const fraction = value - floor;
  if (fraction < 0.5) return floor;
  if (fraction > 0.5) return floor + 1;
  return floor % 2 === 0 ? floor : floor + 1;
}

function clamp(value: number, lo: number, hi: number): number {
  return value < lo ? lo : value > hi ? hi : value;
}
