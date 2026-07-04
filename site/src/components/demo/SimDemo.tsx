import { useCallback, useEffect, useRef, useState } from 'react';
import { ControlPanel } from './ControlPanel';
import { TaskCanvas, type TaskWorldSnapshot } from './TaskCanvas';
import { ReadoutStrip } from './ReadoutStrip';
import { FalandaysReservoir } from '../../simulation/falandays';
import type { FalandaysParams, ReservoirSnapshot, TaskEnv, TaskName } from '../../simulation/types';
import { BASE_PARAMS, taskTuningFor } from '../../simulation/presets';
import { TASKS } from '../../simulation/tasks';

/**
 * setInterval-driven ticker for now — deliberately simple, honest about not
 * yet being the 60fps rAF/ref architecture described in the build plan
 * ("why it won't jank"). That rearchitecture is a separate pass (task 5);
 * this component's job right now is to prove the control surface actually
 * works end to end against a real, ticking sim. No reservoir graph is
 * rendered here — that (and the update-loop diagram) live as static,
 * non-live content in components/explainer/, decoupled from this ticker.
 */
const TICK_INTERVAL_MS = 50;

function makeSim(task: TaskName, params: FalandaysParams, seed = 1): { env: TaskEnv; reservoir: FalandaysReservoir } {
  const env = TASKS[task].createEnv(seed);
  const reservoir = new FalandaysReservoir(env.nReceptors, env.nEffectors, params, seed);
  return { env, reservoir };
}

function buildTaskSnapshot(task: TaskName, envSnapshot: unknown): TaskWorldSnapshot {
  return { task, env: envSnapshot } as TaskWorldSnapshot;
}

export function SimDemo() {
  const [task, setTask] = useState<TaskName>('wall');
  const [params, setParams] = useState<FalandaysParams>(() => ({
    ...BASE_PARAMS,
    ...taskTuningFor('wall'),
  }));
  const [running, setRunning] = useState(false);

  const simRef = useRef(makeSim('wall', params));
  const [reservoirSnap, setReservoirSnap] = useState<ReservoirSnapshot>(() => simRef.current.reservoir.snapshot());
  const [envSnap, setEnvSnap] = useState(() => simRef.current.env.snapshot());

  const syncSnapshots = useCallback(() => {
    setReservoirSnap(simRef.current.reservoir.snapshot());
    setEnvSnap(simRef.current.env.snapshot());
  }, []);

  const step = useCallback(() => {
    const { env, reservoir } = simRef.current;
    const receptors = env.sense();
    reservoir.step(receptors);
    env.step(reservoir.effectorOutputs());
    syncSnapshots();
  }, [syncSnapshots]);

  useEffect(() => {
    if (!running) return;
    const id = setInterval(step, TICK_INTERVAL_MS);
    return () => clearInterval(id);
  }, [running, step]);

  const handleTaskChange = (nextTask: TaskName) => {
    const nextParams = { ...params, ...taskTuningFor(nextTask) };
    simRef.current = makeSim(nextTask, nextParams);
    setTask(nextTask);
    setParams(nextParams);
    syncSnapshots();
  };

  const handleParamsChange = (nextParams: FalandaysParams) => {
    const topologyChanged =
      nextParams.N !== params.N || nextParams.linkP !== params.linkP || nextParams.weightInitStd !== params.weightInitStd;
    if (topologyChanged) {
      simRef.current = makeSim(task, nextParams);
      syncSnapshots();
    } else {
      simRef.current.reservoir.params = nextParams;
    }
    setParams(nextParams);
  };

  const handleReset = () => {
    simRef.current.reservoir.reset();
    simRef.current.env.reset();
    syncSnapshots();
  };

  let spikeCount = 0;
  let sumAct = 0;
  let sumAbsErr = 0;
  let sumTarget = 0;
  for (let i = 0; i < reservoirSnap.nNodes; i++) {
    if (reservoirSnap.spikes[i] > 0) spikeCount += 1;
    sumAct += reservoirSnap.acts[i];
    sumAbsErr += Math.abs(reservoirSnap.errors[i]);
    sumTarget += reservoirSnap.targets[i];
  }

  return (
    <div className="flex min-h-dvh flex-col bg-paper text-ink">
      <div className="grid flex-1 grid-cols-1 gap-px bg-grid lg:grid-cols-[minmax(0,1fr)_320px]">
        <div className="min-h-[420px] bg-paper lg:min-h-0">
          <TaskCanvas snapshot={buildTaskSnapshot(task, envSnap)} />
        </div>
        <div className="bg-paper p-2">
          <ControlPanel
            className="h-full"
            params={params}
            onParamsChange={handleParamsChange}
            task={task}
            onTaskChange={handleTaskChange}
            running={running}
            onTogglePlay={() => setRunning((r) => !r)}
            onStep={step}
            onReset={handleReset}
          />
        </div>
      </div>

      <ReadoutStrip
        tick={reservoirSnap.tick}
        meanActivation={sumAct / reservoirSnap.nNodes}
        meanAbsError={sumAbsErr / reservoirSnap.nNodes}
        meanTarget={sumTarget / reservoirSnap.nNodes}
        spikeCount={spikeCount}
        nNodes={reservoirSnap.nNodes}
        effectorOutputs={reservoirSnap.effectorOutputs}
      />
    </div>
  );
}
