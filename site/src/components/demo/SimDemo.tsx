import { useCallback, useEffect, useRef, useState } from 'react';
import { ArrowCounterClockwise, GearSix, Pause, Play, SkipForward } from '@phosphor-icons/react';
import { DEMO_TASK_NAMES } from '../../simulation/canonical';
import {
  createDemoSimulation,
  defaultDemoNodeParams,
  DEMO_PROTOCOLS,
  runDemoWorldStep,
  type DemoSimulation,
} from '../../simulation/demoRuntime';
import { demoTaskSnapshot, type DemoTaskSnapshot } from '../../simulation/tasks/demo';
import type {
  DemoNodeName,
  DemoNodeParams,
  DemoTaskName,
  FalandaysParams,
  SornParams,
} from '../../simulation/types';
import { ControlPanel } from './ControlPanel';
import { SornControlPanel } from './SornControlPanel';
import { TaskCanvas } from './TaskCanvas';
import { SegmentedControl } from './ui/SegmentedControl';

const VISUAL_INTERVAL_MS = 50;
const MAX_TICKS_PER_FRAME = 8;
const MAIN_THREAD_SLICE_MS = 8;
const PARAMETER_DEBOUNCE_MS = 180;

const TASK_OPTIONS = DEMO_TASK_NAMES.map((value) => ({
  value,
  label: value === 'tracking' ? 'Track' : value === 'cartpole_plank_easy' ? 'CartPole' : 'Pong',
}));

const NODE_OPTIONS: Array<{ value: DemoNodeName; label: string }> = [
  { value: 'falandays', label: 'Falandays' },
  { value: 'sorn', label: 'SORN' },
];

function paramsEqual(left: DemoNodeParams, right: DemoNodeParams): boolean {
  if (left.node !== right.node) return false;
  const leftValues = left.value as unknown as Record<string, unknown>;
  const rightValues = right.value as unknown as Record<string, unknown>;
  const keys = Object.keys(leftValues);
  return keys.length === Object.keys(rightValues).length
    && keys.every((key) => leftValues[key] === rightValues[key]);
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
  const initialTask: DemoTaskName = 'pong';
  const initialNode: DemoNodeName = 'falandays';
  const initialParams = defaultDemoNodeParams(initialNode, initialTask);
  const simRef = useRef<DemoSimulation | null>(null);
  if (simRef.current === null) {
    simRef.current = createDemoSimulation(initialTask, initialParams);
  }

  const [task, setTask] = useState<DemoTaskName>(initialTask);
  const [node, setNode] = useState<DemoNodeName>(initialNode);
  const [params, setParams] = useState<DemoNodeParams>(initialParams);
  const [running, setRunning] = useState(true);
  const [preparing, setPreparing] = useState(true);
  const [detailsOpen, setDetailsOpen] = useState(false);
  const [tick, setTick] = useState(0);
  const [worldSnapshot, setWorldSnapshot] = useState<DemoTaskSnapshot>(() =>
    demoTaskSnapshot(initialTask, simRef.current!.env),
  );

  const taskRef = useRef(task);
  const nodeRef = useRef(node);
  const paramsRef = useRef(params);
  const preparationTokenRef = useRef(0);
  const parameterTimerRef = useRef<number | null>(null);

  const syncDisplay = useCallback(() => {
    const simulation = simRef.current;
    if (!simulation) return;
    setTick(simulation.worldTick);
    setWorldSnapshot(demoTaskSnapshot(simulation.task, simulation.env));
  }, []);

  const prepareSimulation = useCallback((
    nextTask: DemoTaskName,
    nextParams: DemoNodeParams,
    reuseInitial = false,
  ) => {
    const token = ++preparationTokenRef.current;
    const current = simRef.current;
    const simulation = reuseInitial
      && current?.task === nextTask
      && current.node === nextParams.node
      && current.worldTick === 0
      ? current
      : createDemoSimulation(nextTask, nextParams);
    simRef.current = simulation;
    setPreparing(true);
    setTick(0);
    setWorldSnapshot(demoTaskSnapshot(nextTask, simulation.env));

    const warmup = DEMO_PROTOCOLS[nextTask].warmup;
    const advanceWarmup = () => {
      if (preparationTokenRef.current !== token) return;
      const deadline = performance.now() + MAIN_THREAD_SLICE_MS;
      while (simulation.worldTick < warmup && performance.now() < deadline) {
        runDemoWorldStep(simulation);
      }
      if (simulation.worldTick < warmup) {
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
    const protocol = DEMO_PROTOCOLS[simulation.task];
    if (simulation.worldTick >= protocol.horizon || simulation.env.isTerminal?.()) {
      resetCurrentRun();
      return;
    }

    const deadline = performance.now() + MAIN_THREAD_SLICE_MS;
    let advanced = 0;
    while (
      advanced < MAX_TICKS_PER_FRAME
      && simulation.worldTick < protocol.horizon
      && !simulation.env.isTerminal?.()
      && performance.now() < deadline
    ) {
      runDemoWorldStep(simulation);
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
    if (
      simulation.worldTick >= DEMO_PROTOCOLS[simulation.task].horizon
      || simulation.env.isTerminal?.()
    ) {
      resetCurrentRun();
      return;
    }
    runDemoWorldStep(simulation);
    syncDisplay();
  };

  const handleTaskChange = (nextTask: DemoTaskName) => {
    if (parameterTimerRef.current !== null) window.clearTimeout(parameterTimerRef.current);
    const nextParams = defaultDemoNodeParams(nodeRef.current, nextTask);
    taskRef.current = nextTask;
    paramsRef.current = nextParams;
    setTask(nextTask);
    setParams(nextParams);
    prepareSimulation(nextTask, nextParams);
  };

  const handleNodeChange = (nextNode: DemoNodeName) => {
    if (parameterTimerRef.current !== null) window.clearTimeout(parameterTimerRef.current);
    const nextParams = defaultDemoNodeParams(nextNode, taskRef.current);
    nodeRef.current = nextNode;
    paramsRef.current = nextParams;
    setNode(nextNode);
    setParams(nextParams);
    prepareSimulation(taskRef.current, nextParams);
  };

  const queueParamsChange = (nextParams: DemoNodeParams) => {
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

  const restoreDefault = () => {
    const nextParams = defaultDemoNodeParams(nodeRef.current, taskRef.current);
    paramsRef.current = nextParams;
    setParams(nextParams);
    prepareSimulation(taskRef.current, nextParams);
  };

  const isDefault = paramsEqual(params, defaultDemoNodeParams(node, task));
  const status = node === 'falandays' && task !== 'cartpole_plank_easy'
    ? 'canonical v2'
    : 'experimental';

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
            <div className="flex min-w-max items-center gap-1.5">
              <SegmentedControl
                options={NODE_OPTIONS}
                value={node}
                onChange={handleNodeChange}
                ariaLabel="Neuron design"
              />
              <span className="font-mono text-[10px] text-ink-muted" aria-hidden="true">in</span>
              <SegmentedControl
                options={TASK_OPTIONS}
                value={task}
                onChange={handleTaskChange}
                ariaLabel="Task"
              />
            </div>
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
              Preparing the display…
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
          <span className={`font-mono text-[9px] ${isDefault && status === 'canonical v2' ? 'text-teal-ink' : 'text-amber'}`}>
            {isDefault ? status : 'modified'}
          </span>
        </button>

        <aside
          id="bl-demo-settings"
          className="bl-demo-settings min-h-0 border-t border-grid bg-card"
          data-open={detailsOpen ? 'true' : 'false'}
        >
          {params.node === 'falandays' ? (
            <ControlPanel
              task={task}
              params={params.value as FalandaysParams}
              isDefault={isDefault}
              onParamsChange={(value) => queueParamsChange({ node: 'falandays', value })}
              onRestoreDefault={restoreDefault}
            />
          ) : (
            <SornControlPanel
              params={params.value as SornParams}
              isDefault={isDefault}
              onParamsChange={(value) => queueParamsChange({ node: 'sorn', value })}
              onRestoreDefault={restoreDefault}
            />
          )}
        </aside>
      </div>
    </section>
  );
}
