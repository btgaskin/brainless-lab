import { describe, expect, test } from 'bun:test';
import { DEMO_TASK_NAMES } from './canonical';
import {
  createDemoSimulation,
  defaultDemoNodeParams,
  runDemoWorldStep,
} from './demoRuntime';
import type { DemoNodeName } from './types';

const NODES: DemoNodeName[] = ['falandays', 'sorn'];

describe('landing demo runtime', () => {
  test('constructs both neuron designs in every landing task', () => {
    for (const task of DEMO_TASK_NAMES) {
      for (const node of NODES) {
        const simulation = createDemoSimulation(task, defaultDemoNodeParams(node, task));
        expect(simulation.task).toBe(task);
        expect(simulation.node).toBe(node);
        expect(simulation.worldTick).toBe(0);
        runDemoWorldStep(simulation);
        expect(simulation.worldTick).toBe(1);
        expect(simulation.reservoir.currentTick).toBe(simulation.env.neuralFrames ?? 1);
      }
    }
  });

  test('reconstructs the same task and node trajectory from the same display seeds', () => {
    for (const task of DEMO_TASK_NAMES) {
      for (const node of NODES) {
        const first = createDemoSimulation(task, defaultDemoNodeParams(node, task));
        const second = createDemoSimulation(task, defaultDemoNodeParams(node, task));
        for (let step = 0; step < 3; step++) {
          runDemoWorldStep(first);
          runDemoWorldStep(second);
        }
        expect(first.env.snapshot()).toEqual(second.env.snapshot());
        expect(first.reservoir.effectorOutputs()).toEqual(second.reservoir.effectorOutputs());
      }
    }
  });
});
