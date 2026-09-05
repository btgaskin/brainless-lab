import { CANONICAL_CORE_V2, canonicalParamsFor } from './canonical';
import { DISPLAY_CASES } from './displayCases';
import { FalandaysReservoir } from './falandays';
import { derivePortSeed } from './rng';
import { SornReservoir } from './sorn';
import { DEMO_TASKS } from './tasks/demo';
import { taskTuningFor } from './presets';
import {
  DEFAULT_PARAMS,
  DEFAULT_SORN_PARAMS,
  type DemoNodeName,
  type DemoNodeParams,
  type DemoTaskName,
  type FalandaysParams,
  type TaskEnv,
} from './types';

export interface DemoReservoir {
  readonly currentTick: number;
  step(receptors: ArrayLike<number>): Float64Array;
  effectorOutputs(): number[];
}

export interface DemoSimulation {
  task: DemoTaskName;
  node: DemoNodeName;
  rootSeed: number;
  worldTick: number;
  env: TaskEnv;
  reservoir: DemoReservoir;
}

export interface DemoSimulationSeeds {
  topology: number;
  world: number;
}

export interface DemoProtocol {
  horizon: number;
  warmup: number;
  rootSeed: number;
  seeds: DemoSimulationSeeds;
}

function derivedSeeds(rootSeed: number): DemoSimulationSeeds {
  return {
    topology: derivePortSeed(rootSeed, 'topology', 1, 1, 1),
    world: derivePortSeed(rootSeed, 'world', 1, 1),
  };
}

export const DEMO_PROTOCOLS: Record<DemoTaskName, DemoProtocol> = {
  pong: {
    horizon: CANONICAL_CORE_V2.pong.horizon,
    warmup: CANONICAL_CORE_V2.pong.warmup,
    rootSeed: DISPLAY_CASES.pong.rootSeed,
    seeds: {
      topology: DISPLAY_CASES.pong.topologySeed,
      world: DISPLAY_CASES.pong.worldSeed,
    },
  },
  tracking: {
    horizon: CANONICAL_CORE_V2.tracking.horizon,
    warmup: CANONICAL_CORE_V2.tracking.warmup,
    rootSeed: DISPLAY_CASES.tracking.rootSeed,
    seeds: {
      topology: DISPLAY_CASES.tracking.topologySeed,
      world: DISPLAY_CASES.tracking.worldSeed,
    },
  },
  cartpole_plank_easy: {
    horizon: 1_000,
    warmup: 0,
    rootSeed: 74_001,
    seeds: derivedSeeds(74_001),
  },
};

function falandaysParamsFor(task: DemoTaskName): FalandaysParams {
  if (task === 'pong' || task === 'tracking') return canonicalParamsFor(task);
  const tuning = taskTuningFor(task);
  return {
    ...DEFAULT_PARAMS,
    N: tuning.N,
    inputWeight: tuning.inputWeight,
    lrateWmat: tuning.lrateWmat,
    lrateTarg: tuning.lrateTarg,
    weightInitMode: tuning.weightInitMode,
  };
}

export function defaultDemoNodeParams(node: DemoNodeName, task: DemoTaskName): DemoNodeParams {
  return node === 'falandays'
    ? { node, value: falandaysParamsFor(task) }
    : { node, value: { ...DEFAULT_SORN_PARAMS } };
}

export function createDemoSimulation(
  task: DemoTaskName,
  params: DemoNodeParams,
): DemoSimulation {
  const protocol = DEMO_PROTOCOLS[task];
  const env = DEMO_TASKS[task].createEnv(protocol.seeds.world);
  const reservoir = params.node === 'falandays'
    ? new FalandaysReservoir(env.nReceptors, env.nEffectors, params.value, protocol.seeds.topology)
    : new SornReservoir(env.nReceptors, env.nEffectors, params.value, protocol.seeds.topology);
  return {
    task,
    node: params.node,
    rootSeed: protocol.rootSeed,
    worldTick: 0,
    env,
    reservoir,
  };
}

export function runDemoWorldStep(simulation: DemoSimulation): void {
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
  simulation.worldTick += 1;
}
