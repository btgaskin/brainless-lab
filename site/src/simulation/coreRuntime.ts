import { FalandaysReservoir } from './falandays';
import { derivePortSeed } from './rng';
import { CORE_TASKS } from './tasks/core';
import type { PongSnapshot } from './tasks/pong';
import type { TrackingSnapshot } from './tasks/tracking';
import type { WallSnapshot } from './tasks/wall';
import type { CoreTaskName, FalandaysParams, TaskEnv } from './types';

export interface CoreSimulation {
  task: CoreTaskName;
  rootSeed: number;
  env: TaskEnv;
  reservoir: FalandaysReservoir;
}

export interface CoreSimulationSeeds {
  topology: number;
  world: number;
}

export function createCoreSimulationFromSeeds(
  task: CoreTaskName,
  params: FalandaysParams,
  rootSeed: number,
  seeds: CoreSimulationSeeds,
): CoreSimulation {
  const env = CORE_TASKS[task].createEnv(seeds.world);
  const reservoir = new FalandaysReservoir(env.nReceptors, env.nEffectors, params, seeds.topology);
  return { task, rootSeed, env, reservoir };
}

export function createCoreSimulation(
  task: CoreTaskName,
  params: FalandaysParams,
  rootSeed: number,
): CoreSimulation {
  // Mirror one trial-scoped EvaluationSpec construction at block 1, trial 1,
  // with one agent occupying slot 1.
  const worldSeed = derivePortSeed(rootSeed, 'world', 1, 1);
  const topologySeed = derivePortSeed(rootSeed, 'topology', 1, 1, 1);
  return createCoreSimulationFromSeeds(task, params, rootSeed, { topology: topologySeed, world: worldSeed });
}

export function runCoreWorldStep(simulation: CoreSimulation): void {
  const { env, reservoir } = simulation;
  const neuralFrames = env.neuralFrames ?? 1;
  const effectorFrames: number[][] = [];
  for (let frame = 0; frame < neuralFrames; frame++) {
    const receptors = env.senseFrame ? env.senseFrame(frame) : env.sense();
    reservoir.step(receptors);
    effectorFrames.push(reservoir.effectorOutputs());
  }
  const effectors = env.reduceEffectors
    ? env.reduceEffectors(effectorFrames)
    : effectorFrames[effectorFrames.length - 1];
  env.step(effectors);
}

export function runCoreTicks(simulation: CoreSimulation, ticks: number): void {
  for (let tick = 0; tick < ticks; tick++) runCoreWorldStep(simulation);
}

export interface CoreDevelopmentOutcome {
  key: 'hit_rate' | 'track_score' | 'nav_score';
  raw: number;
  window: number;
}

/** Development-only scorer used by the display-root selection script. */
export function evaluateCoreDisplayCandidate(
  simulation: CoreSimulation,
  horizon: number,
  warmup: number,
): CoreDevelopmentOutcome {
  runCoreTicks(simulation, warmup);
  const scoredTicks = horizon - warmup;

  if (simulation.task === 'tracking') {
    let cosError = 0;
    for (let tick = 0; tick < scoredTicks; tick++) {
      runCoreWorldStep(simulation);
      const snapshot = simulation.env.snapshot() as TrackingSnapshot;
      const delta = ((snapshot.headingDeg - snapshot.stimulusDeg + 180) % 360 + 360) % 360 - 180;
      cosError += Math.cos((delta * Math.PI) / 180);
    }
    return { key: 'track_score', raw: scoredTicks === 0 ? 0 : cosError / scoredTicks, window: scoredTicks };
  }

  if (simulation.task === 'pong') {
    let previous = simulation.env.snapshot() as PongSnapshot;
    let hits = 0;
    let misses = 0;
    for (let tick = 0; tick < scoredTicks; tick++) {
      runCoreWorldStep(simulation);
      const snapshot = simulation.env.snapshot() as PongSnapshot;
      hits += snapshot.hits - previous.hits;
      misses += snapshot.misses - previous.misses;
      previous = snapshot;
    }
    const events = hits + misses;
    return { key: 'hit_rate', raw: events === 0 ? 0 : hits / events, window: scoredTicks };
  }

  let previous = simulation.env.snapshot() as WallSnapshot;
  let collisions = 0;
  let distance = 0;
  for (let tick = 0; tick < scoredTicks; tick++) {
    runCoreWorldStep(simulation);
    const snapshot = simulation.env.snapshot() as WallSnapshot;
    collisions += snapshot.collided ? 1 : 0;
    distance += Math.hypot(snapshot.x - previous.x, snapshot.y - previous.y);
    previous = snapshot;
  }
  const effectiveWindow = Math.max(1, scoredTicks);
  const collisionFreeRate = Math.max(0, Math.min(1, 1 - collisions / effectiveWindow));
  const movementGate = Math.max(0, Math.min(1, distance / (0.1 * effectiveWindow)));
  return { key: 'nav_score', raw: collisionFreeRate * movementGate, window: scoredTicks };
}
