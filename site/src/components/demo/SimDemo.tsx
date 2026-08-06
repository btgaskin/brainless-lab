import { useCallback, useEffect, useRef, useState } from 'react';
import { ArrowCounterClockwise, GearSix, Pause, Play, SkipForward } from '@phosphor-icons/react';
import { CANONICAL_CORE_V2, CORE_TASK_NAMES, canonicalParamsFor } from '../../simulation/canonical';
import {
  createCoreSimulationFromSeeds,
  runCoreWorldStep,
  type CoreSimulation,
} from '../../simulation/coreRuntime';
import { DISPLAY_CASES } from '../../simulation/displayCases';
import { coreTaskSnapshot, type CoreTaskSnapshot } from '../../simulation/tasks/core';
import type { CoreTaskName, FalandaysParams } from '../../simulation/types';
import { ControlPanel } from './ControlPanel';
import { TaskCanvas } from './TaskCanvas';
import { SegmentedControl } from './ui/SegmentedControl';

const VISUAL_INTERVAL_MS = 50;
const MAX_TICKS_PER_FRAME = 8;
const MAIN_THREAD_SLICE_MS = 8;
const PARAMETER_DEBOUNCE_MS = 180;

const TASK_OPTIONS = CORE_TASK_NAMES.map((value) => ({
  value,
  label: value === 'tracking' ? 'Track' : value[0].toUpperCase() + value.slice(1),
}));

function paramsEqual(left: FalandaysParams, right: FalandaysParams): boolean {
  return (Object.keys(left) as Array<keyof FalandaysParams>).every((key) => left[key] === right[key]);
}

function createDisplaySimulation(task: CoreTaskName, params: FalandaysParams): CoreSimulation {
  const display = DISPLAY_CASES[task];
  return createCoreSimulationFromSeeds(task, params, display.rootSeed, {
    topology: display.topologySeed,
    world: display.worldSeed,
  });
}

function ToolbarButton({
  onClick,
  label,
  disabled = false,
  children,
}: {
  onClick: () => void;
  label: string;
  disabled?: boolean;
  children: React.ReactNode;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={disabled}
      aria-label={label}
      title={label}
      className="flex h-7 w-7 items-center justify-center rounded-md text-ink-soft transition-colors hover:bg-paper hover:text-ink focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-teal active:translate-y-px disabled:cursor-wait disabled:opacity-40"
    >
      {children}
    </button>
  );
}

export function SimDemo() {
  const initialTask: CoreTaskName = 'pong';
  const initialParams = canonicalParamsFor(initialTask);
  const simRef = useRef<CoreSimulation | null>(null);
  if (simRef.current === null) {
    simRef.current = createDisplaySimulation(initialTask, initialParams);
  }

  const [task, setTask] = useState<CoreTaskName>(initialTask);
  const [params, setParams] = useState<FalandaysParams>(initialParams);
  const [running, setRunning] = useState(true);
  const [preparing, setPreparing] = useState(true);
  const [detailsOpen, setDetailsOpen] = useState(false);
  const [tick, setTick] = useState(0);
  const [worldSnapshot, setWorldSnapshot] = useState<CoreTaskSnapshot>(() =>
    coreTaskSnapshot(initialTask, simRef.current!.env),
  );

  const taskRef = useRef(task);
  const paramsRef = useRef(params);
  const preparationTokenRef = useRef(0);
  const parameterTimerRef = useRef<number | null>(null);

  const syncDisplay = useCallback(() => {
    const simulation = simRef.current;
    if (!simulation) return;
    setTick(simulation.reservoir.currentTick);
    setWorldSnapshot(coreTaskSnapshot(simulation.task, simulation.env));
  }, []);

  const prepareSimulation = useCallback((
    nextTask: CoreTaskName,
    nextParams: FalandaysParams,
    reuseInitial = false,
  ) => {
    const token = ++preparationTokenRef.current;
    const current = simRef.current;
    const simulation = reuseInitial
      && current?.task === nextTask
      && current.reservoir.currentTick === 0
      ? current
      : createDisplaySimulation(nextTask, nextParams);
    simRef.current = simulation;
    setPreparing(true);
    setTick(0);
    setWorldSnapshot(coreTaskSnapshot(nextTask, simulation.env));

    const warmup = CANONICAL_CORE_V2[nextTask].warmup;
    const advanceWarmup = () => {
      if (preparationTokenRef.current !== token) return;
      const deadline = performance.now() + MAIN_THREAD_SLICE_MS;
      while (simulation.reservoir.currentTick < warmup && performance.now() < deadline) {
        runCoreWorldStep(simulation);
      }
      if (simulation.reservoir.currentTick < warmup) {
        window.setTimeout(advanceWarmup, 0);
        return;
      }
      syncDisplay();
      setPreparing(false);
    };
    window.setTimeout(advanceWarmup, 0);
  }, [syncDisplay]);

  useEffect(() => {
    prepareSimulation(initialTask, initialParams, true);
    return () => {
      preparationTokenRef.current += 1;
      if (parameterTimerRef.current !== null) window.clearTimeout(parameterTimerRef.current);
    };
  }, [prepareSimulation]);

  useEffect(() => {
    if (window.matchMedia?.('(prefers-reduced-motion: reduce)').matches) setRunning(false);
  }, []);

  const resetCurrentRun = useCallback(() => {
    prepareSimulation(taskRef.current, paramsRef.current);
  }, [prepareSimulation]);

  const advanceFrame = useCallback(() => {
    const simulation = simRef.current;
    if (!simulation || preparing) return;
    const protocol = CANONICAL_CORE_V2[simulation.task];
    if (simulation.reservoir.currentTick >= protocol.horizon) {
      resetCurrentRun();
      return;
    }

    const deadline = performance.now() + MAIN_THREAD_SLICE_MS;
    let advanced = 0;
    while (
      advanced < MAX_TICKS_PER_FRAME
      && simulation.reservoir.currentTick < protocol.horizon
      && performance.now() < deadline
    ) {
      runCoreWorldStep(simulation);
      advanced += 1;
    }
    syncDisplay();
  }, [preparing, resetCurrentRun, syncDisplay]);

  useEffect(() => {
    if (!running || preparing) return;
    const id = window.setInterval(advanceFrame, VISUAL_INTERVAL_MS);
    return () => window.clearInterval(id);
  }, [advanceFrame, preparing, running]);

  const advanceOneTick = () => {
    const simulation = simRef.current;
    if (!simulation || preparing) return;
    if (simulation.reservoir.currentTick >= CANONICAL_CORE_V2[simulation.task].horizon) {
      resetCurrentRun();
      return;
    }
    runCoreWorldStep(simulation);
    syncDisplay();
  };

  const handleTaskChange = (nextTask: CoreTaskName) => {
    if (parameterTimerRef.current !== null) window.clearTimeout(parameterTimerRef.current);
    const nextParams = canonicalParamsFor(nextTask);
    taskRef.current = nextTask;
    paramsRef.current = nextParams;
    setTask(nextTask);
    setParams(nextParams);
    prepareSimulation(nextTask, nextParams);
  };

  const handleParamsChange = (nextParams: FalandaysParams) => {
    paramsRef.current = nextParams;
    setParams(nextParams);
    preparationTokenRef.current += 1;
    setPreparing(true);
    if (parameterTimerRef.current !== null) window.clearTimeout(parameterTimerRef.current);
    parameterTimerRef.current = window.setTimeout(() => {
      parameterTimerRef.current = null;
      prepareSimulation(taskRef.current, paramsRef.current);
    }, PARAMETER_DEBOUNCE_MS);
  };

  const restoreCanonical = () => {
    const nextParams = canonicalParamsFor(taskRef.current);
    paramsRef.current = nextParams;
    setParams(nextParams);
    prepareSimulation(taskRef.current, nextParams);
  };

  const isCanonical = paramsEqual(params, canonicalParamsFor(task));

  return (
    <section className="overflow-hidden rounded-xl border border-grid bg-paper text-ink shadow-[0_1px_2px_rgba(30,30,25,0.06),0_10px_28px_-18px_rgba(30,30,25,0.25)]">
      <div className="border-b border-grid bg-card px-2.5 py-1.5">
        <div className="flex items-center gap-1.5">
          <button
            type="button"
            onClick={() => setRunning((value) => !value)}
            disabled={preparing}
            aria-label={running ? 'Pause' : 'Play'}
            title={running ? 'Pause' : 'Play'}
            className="flex h-7 w-7 shrink-0 items-center justify-center rounded-md bg-teal text-paper transition-colors hover:bg-teal-ink focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-teal active:translate-y-px disabled:cursor-wait disabled:opacity-50"
          >
            {running ? <Pause size={14} weight="fill" /> : <Play size={14} weight="fill" />}
          </button>
          <ToolbarButton onClick={advanceOneTick} label="Step one world tick" disabled={preparing}>
            <SkipForward size={14} weight="fill" />
          </ToolbarButton>
          <ToolbarButton onClick={resetCurrentRun} label="Reset this display run">
            <ArrowCounterClockwise size={14} />
          </ToolbarButton>

          <div className="mx-0.5 h-4 w-px shrink-0 bg-grid" aria-hidden="true" />

          <div className="min-w-0 overflow-x-auto">
            <SegmentedControl options={TASK_OPTIONS} value={task} onChange={handleTaskChange} />
          </div>

          <span className="ml-auto hidden shrink-0 font-mono text-[10px] tabular-nums text-ink-muted sm:inline">
            {preparing ? 'preparing' : `t ${tick}`}
          </span>
        </div>
      </div>

      <div className="bl-demo-body">
        <div className="bl-demo-canvas p-2.5 sm:p-3">
          <TaskCanvas snapshot={worldSnapshot} />
          {preparing ? (
            <div className="pointer-events-none absolute inset-2.5 grid place-items-center rounded-lg bg-paper/70 font-mono text-[10px] text-ink-muted backdrop-blur-[1px] sm:inset-3">
              Preparing the scored interval…
            </div>
          ) : null}
        </div>

        <button
          type="button"
          className="bl-demo-details-toggle flex w-full items-center justify-between border-t border-grid bg-card px-3 py-2 text-left text-[11px] text-ink-soft transition-colors hover:text-ink focus-visible:outline-2 focus-visible:outline-offset-[-2px] focus-visible:outline-teal"
          aria-expanded={detailsOpen}
          aria-controls="bl-demo-settings"
          onClick={() => setDetailsOpen((value) => !value)}
        >
          <span className="flex items-center gap-1.5"><GearSix size={13} /> Settings</span>
          <span className={`font-mono text-[9px] ${isCanonical ? 'text-teal-ink' : 'text-amber'}`}>
            {isCanonical ? 'canonical v2' : 'modified'}
          </span>
        </button>

        <aside
          id="bl-demo-settings"
          className="bl-demo-settings min-h-0 border-t border-grid bg-card"
          data-open={detailsOpen ? 'true' : 'false'}
        >
          <ControlPanel
            params={params}
            isCanonical={isCanonical}
            onParamsChange={handleParamsChange}
            onRestoreCanonical={restoreCanonical}
          />
        </aside>
      </div>
    </section>
  );
}
