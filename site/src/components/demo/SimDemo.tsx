import { useCallback, useEffect, useRef, useState } from 'react';
import { Play, Pause, SkipForward, ArrowCounterClockwise } from '@phosphor-icons/react';
import { ControlPanel } from './ControlPanel';
import { SegmentedControl } from './ui/SegmentedControl';
import { TaskCanvas, type TaskWorldSnapshot } from './TaskCanvas';
import { FalandaysReservoir } from '../../simulation/falandays';
import type {
  FalandaysParams,
  PlankCartPoleTaskName,
  ReservoirSnapshot,
  TaskEnv,
  TaskName,
} from '../../simulation/types';
import { BASE_PARAMS, taskTuningFor } from '../../simulation/presets';
import { TASKS } from '../../simulation/tasks';
import {
  isPlankCartPoleTask,
  plankCartPoleLevel,
  PLANK_CARTPOLE_LEVELS,
  type PlankCartPoleLevelName,
} from '../../simulation/tasks/cartpolePlank';

/**
 * setInterval-driven ticker — deliberately simple, honest about not yet being
 * the 60fps rAF/ref architecture described in the build plan. The Plank tasks
 * run their declared 24 native neural frames within each 20Hz world step.
 * The demo autoplays on mount (paused only for reduced-motion users) so the
 * landing page is alive the moment it loads.
 */
const TICK_INTERVAL_MS = 50;
const TERMINAL_HOLD_TICKS = 16;

type TaskFamily = 'pong' | 'tracking' | 'wall' | 'plank';

const TASK_OPTIONS: Array<{ value: TaskFamily; label: string }> = [
  { value: 'pong', label: 'Pong' },
  { value: 'tracking', label: 'Track' },
  { value: 'wall', label: 'Wall' },
  { value: 'plank', label: 'CartPole' },
];

const PLANK_LEVEL_OPTIONS: Array<{ value: PlankCartPoleLevelName; label: string }> = [
  { value: 'easy', label: 'Easy' },
  { value: 'medium', label: 'Medium' },
  { value: 'hard', label: 'Hard' },
  { value: 'hardest', label: 'Hardest' },
];

function makeSim(task: TaskName, params: FalandaysParams, seed = 1): { env: TaskEnv; reservoir: FalandaysReservoir } {
  const env = TASKS[task].createEnv(seed);
  const reservoir = new FalandaysReservoir(env.nReceptors, env.nEffectors, params, seed);
  return { env, reservoir };
}

function buildTaskSnapshot(task: TaskName, envSnapshot: unknown): TaskWorldSnapshot {
  return { task, env: envSnapshot } as TaskWorldSnapshot;
}

function runWorldStep(env: TaskEnv, reservoir: FalandaysReservoir): void {
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

function taskForLevel(level: PlankCartPoleLevelName): PlankCartPoleTaskName {
  return PLANK_CARTPOLE_LEVELS[level].task;
}

function ToolbarButton({ onClick, label, children }: { onClick: () => void; label: string; children: React.ReactNode }) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-label={label}
      title={label}
      className="flex h-7 w-7 items-center justify-center rounded-md text-ink-soft transition-colors hover:bg-paper hover:text-ink active:translate-y-px"
    >
      {children}
    </button>
  );
}

export function SimDemo() {
  const [task, setTask] = useState<TaskName>('pong');
  const [params, setParams] = useState<FalandaysParams>(() => ({
    ...BASE_PARAMS,
    ...taskTuningFor('pong'),
  }));
  const [running, setRunning] = useState(true);
  const lastPlankLevelRef = useRef<PlankCartPoleLevelName>('easy');
  const terminalHoldRef = useRef(0);

  const simRef = useRef(makeSim('pong', params));
  const [reservoirSnap, setReservoirSnap] = useState<ReservoirSnapshot>(() => simRef.current.reservoir.snapshot());
  const [envSnap, setEnvSnap] = useState(() => simRef.current.env.snapshot());

  const syncSnapshots = useCallback(() => {
    setReservoirSnap(simRef.current.reservoir.snapshot());
    setEnvSnap(simRef.current.env.snapshot());
  }, []);

  const step = useCallback(() => {
    const { env, reservoir } = simRef.current;
    if (env.isTerminal?.()) {
      // Keep the terminal pose legible, then begin a fresh demo episode with
      // both world and plastic state reset. Episode dynamics remain unchanged.
      terminalHoldRef.current += 1;
      if (terminalHoldRef.current >= TERMINAL_HOLD_TICKS) {
        reservoir.reset();
        env.reset();
        terminalHoldRef.current = 0;
      }
      syncSnapshots();
      return;
    }
    runWorldStep(env, reservoir);
    syncSnapshots();
  }, [syncSnapshots]);

  useEffect(() => {
    if (!running) return;
    const id = setInterval(step, TICK_INTERVAL_MS);
    return () => clearInterval(id);
  }, [running, step]);

  // Autoplay everywhere except for reduced-motion users.
  useEffect(() => {
    if (window.matchMedia?.('(prefers-reduced-motion: reduce)').matches) setRunning(false);
  }, []);

  const handleTaskChange = (nextTask: TaskName) => {
    const nextParams = { ...params, ...taskTuningFor(nextTask) };
    simRef.current = makeSim(nextTask, nextParams);
    setTask(nextTask);
    setParams(nextParams);
    terminalHoldRef.current = 0;
    syncSnapshots();
  };

  const handleTaskFamilyChange = (family: TaskFamily) => {
    handleTaskChange(family === 'plank' ? taskForLevel(lastPlankLevelRef.current) : family);
  };

  const handlePlankLevelChange = (level: PlankCartPoleLevelName) => {
    lastPlankLevelRef.current = level;
    handleTaskChange(taskForLevel(level));
  };

  const handleParamsChange = (nextParams: FalandaysParams) => {
    const topologyChanged =
      nextParams.N !== params.N || nextParams.linkP !== params.linkP || nextParams.weightInitStd !== params.weightInitStd;
    if (topologyChanged) {
      simRef.current = makeSim(task, nextParams);
      terminalHoldRef.current = 0;
      syncSnapshots();
    } else {
      simRef.current.reservoir.params = nextParams;
    }
    setParams(nextParams);
  };

  const handleReset = () => {
    simRef.current.reservoir.reset();
    simRef.current.env.reset();
    terminalHoldRef.current = 0;
    syncSnapshots();
  };

  const taskFamily: TaskFamily = isPlankCartPoleTask(task) ? 'plank' : task;
  const plankLevel = isPlankCartPoleTask(task)
    ? plankCartPoleLevel(task).name
    : lastPlankLevelRef.current;

  return (
    <section className="overflow-hidden rounded-xl border border-grid bg-paper text-ink shadow-[0_1px_2px_rgba(30,30,25,0.06),0_10px_28px_-18px_rgba(30,30,25,0.25)]">
      {/* Toolbar: transport + task switcher + tick readout */}
      <div className="border-b border-grid bg-card px-2.5 py-1.5">
        <div className="flex items-center gap-1.5">
          <button
            type="button"
            onClick={() => setRunning((r) => !r)}
            aria-label={running ? 'Pause' : 'Play'}
            title={running ? 'Pause' : 'Play'}
            className="flex h-7 w-7 shrink-0 items-center justify-center rounded-md bg-teal text-paper transition-colors hover:bg-teal-ink active:translate-y-px"
          >
            {running ? <Pause size={14} weight="fill" /> : <Play size={14} weight="fill" />}
          </button>
          <ToolbarButton onClick={step} label="Step one world tick">
            <SkipForward size={14} weight="fill" />
          </ToolbarButton>
          <ToolbarButton onClick={handleReset} label="Reset">
            <ArrowCounterClockwise size={14} />
          </ToolbarButton>

          <div className="mx-0.5 h-4 w-px shrink-0 bg-grid" aria-hidden="true" />

          <div className="min-w-0 overflow-x-auto">
            <SegmentedControl options={TASK_OPTIONS} value={taskFamily} onChange={handleTaskFamilyChange} />
          </div>

          <span className="ml-auto hidden shrink-0 font-mono text-[10px] tabular-nums text-ink-muted sm:inline">
            t {reservoirSnap.tick}
          </span>
        </div>

        {taskFamily === 'plank' ? (
          <div className="mt-1.5 flex items-center gap-2 border-t border-grid/70 pt-1.5">
            <span className="shrink-0 font-mono text-[9px] uppercase tracking-wide text-ink-muted">
              level
            </span>
            <div className="min-w-0 overflow-x-auto">
              <SegmentedControl
                options={PLANK_LEVEL_OPTIONS}
                value={plankLevel}
                onChange={handlePlankLevelChange}
              />
            </div>
            <span className="ml-auto hidden shrink-0 font-mono text-[9px] uppercase tracking-wide text-amber sm:inline">
              experimental
            </span>
          </div>
        ) : null}
      </div>

      {/* Body: world view + parameter column */}
      <div className="grid grid-cols-1 md:grid-cols-[minmax(0,1fr)_232px]">
        <div className="p-3 max-md:h-[300px] md:aspect-[3/2]">
          <TaskCanvas snapshot={buildTaskSnapshot(task, envSnap)} />
        </div>
        <div className="min-h-0 border-t border-grid bg-card md:overflow-y-auto md:border-l md:border-t-0">
          <ControlPanel params={params} onParamsChange={handleParamsChange} />
        </div>
      </div>
    </section>
  );
}
