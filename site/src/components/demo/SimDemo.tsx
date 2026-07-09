import { useCallback, useEffect, useRef, useState } from 'react';
import { Play, Pause, SkipForward, ArrowCounterClockwise } from '@phosphor-icons/react';
import { ControlPanel } from './ControlPanel';
import { SegmentedControl } from './ui/SegmentedControl';
import { TaskCanvas, type TaskWorldSnapshot } from './TaskCanvas';
import { FalandaysReservoir } from '../../simulation/falandays';
import type { FalandaysParams, ReservoirSnapshot, TaskEnv, TaskName } from '../../simulation/types';
import { BASE_PARAMS, taskTuningFor } from '../../simulation/presets';
import { TASKS } from '../../simulation/tasks';

/**
 * setInterval-driven ticker — deliberately simple, honest about not yet being
 * the 60fps rAF/ref architecture described in the build plan. At N=200 a tick
 * is trivial array math, so 20Hz via setState is comfortably jank-free.
 * The demo autoplays on mount (paused only for reduced-motion users) so the
 * landing page is alive the moment it loads.
 */
const TICK_INTERVAL_MS = 50;

const TASK_OPTIONS: Array<{ value: TaskName; label: string }> = [
  { value: 'pong', label: 'Pong' },
  { value: 'tracking', label: 'Track' },
  { value: 'wall', label: 'Wall' },
];

function makeSim(task: TaskName, params: FalandaysParams, seed = 1): { env: TaskEnv; reservoir: FalandaysReservoir } {
  const env = TASKS[task].createEnv(seed);
  const reservoir = new FalandaysReservoir(env.nReceptors, env.nEffectors, params, seed);
  return { env, reservoir };
}

function buildTaskSnapshot(task: TaskName, envSnapshot: unknown): TaskWorldSnapshot {
  return { task, env: envSnapshot } as TaskWorldSnapshot;
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

  const simRef = useRef(makeSim('pong', params));
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

  // Autoplay everywhere except for reduced-motion users.
  useEffect(() => {
    if (window.matchMedia?.('(prefers-reduced-motion: reduce)').matches) setRunning(false);
  }, []);

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

  return (
    <section className="overflow-hidden rounded-xl border border-grid bg-paper text-ink shadow-[0_1px_2px_rgba(30,30,25,0.06),0_10px_28px_-18px_rgba(30,30,25,0.25)]">
      {/* Toolbar: transport + task switcher + tick readout */}
      <div className="flex items-center gap-1.5 border-b border-grid bg-card px-2.5 py-1.5">
        <button
          type="button"
          onClick={() => setRunning((r) => !r)}
          aria-label={running ? 'Pause' : 'Play'}
          title={running ? 'Pause' : 'Play'}
          className="flex h-7 w-7 items-center justify-center rounded-md bg-teal text-paper transition-colors hover:bg-teal-ink active:translate-y-px"
        >
          {running ? <Pause size={14} weight="fill" /> : <Play size={14} weight="fill" />}
        </button>
        <ToolbarButton onClick={step} label="Step one tick">
          <SkipForward size={14} weight="fill" />
        </ToolbarButton>
        <ToolbarButton onClick={handleReset} label="Reset">
          <ArrowCounterClockwise size={14} />
        </ToolbarButton>

        <div className="mx-1 h-4 w-px bg-grid" aria-hidden="true" />

        <SegmentedControl options={TASK_OPTIONS} value={task} onChange={handleTaskChange} />

        <span className="ml-auto hidden font-mono text-[10px] tabular-nums text-ink-muted sm:inline">
          t {reservoirSnap.tick}
        </span>
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
