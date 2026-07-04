import { Play, Pause, SkipForward, ArrowCounterClockwise } from '@phosphor-icons/react';
import { Slider } from './ui/Slider';
import { Toggle } from './ui/Toggle';
import { SegmentedControl } from './ui/SegmentedControl';
import type { FalandaysParams, TaskName } from '../../simulation/types';

export interface ControlPanelProps {
  params: FalandaysParams;
  onParamsChange: (params: FalandaysParams) => void;
  task: TaskName;
  onTaskChange: (task: TaskName) => void;
  running: boolean;
  onTogglePlay: () => void;
  onStep: () => void;
  onReset: () => void;
  className?: string;
}

const TASK_OPTIONS: Array<{ value: TaskName; label: string }> = [
  { value: 'wall', label: 'Wall' },
  { value: 'tracking', label: 'Track' },
  { value: 'pong', label: 'Pong' },
];

function IconButton({ onClick, label, children }: { onClick: () => void; label: string; children: React.ReactNode }) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-label={label}
      className="flex h-8 w-8 items-center justify-center rounded-md text-ink-soft transition-colors hover:bg-paper hover:text-ink active:translate-y-px"
    >
      {children}
    </button>
  );
}

/**
 * The parameter panel — a plain card in the same palette as the rest of the
 * site (src/viz/Style.jl's identity: paper/ink/teal/amber), not a separate
 * dark "instrument" register. Sans+mono throughout, per the taste skill's
 * dashboard-UI rule.
 */
export function ControlPanel({ params, onParamsChange, task, onTaskChange, running, onTogglePlay, onStep, onReset, className }: ControlPanelProps) {
  const set = <K extends keyof FalandaysParams>(key: K, value: FalandaysParams[K]) =>
    onParamsChange({ ...params, [key]: value });

  return (
    <div
      className={`flex flex-col gap-4 overflow-y-auto rounded-lg border border-grid bg-card p-4 font-mono shadow-[0_1px_2px_rgba(30,30,25,0.06),0_6px_20px_-12px_rgba(30,30,25,0.18)] ${className ?? ''}`}
    >
      <div className="flex items-center gap-1">
        <IconButton onClick={onTogglePlay} label={running ? 'Pause' : 'Play'}>
          {running ? <Pause size={16} weight="fill" /> : <Play size={16} weight="fill" />}
        </IconButton>
        <IconButton onClick={onStep} label="Step">
          <SkipForward size={16} weight="fill" />
        </IconButton>
        <IconButton onClick={onReset} label="Reset">
          <ArrowCounterClockwise size={16} />
        </IconButton>
      </div>

      <SegmentedControl options={TASK_OPTIONS} value={task} onChange={onTaskChange} />

      <div className="h-px bg-grid" />

      <div className="flex flex-col gap-3">
        <Slider label="target floor" value={params.targetFloor} min={0.2} max={3} step={0.05} onChange={(v) => set('targetFloor', v)} />
        <Slider label="leak" value={params.leak} min={0} max={0.9} step={0.01} onChange={(v) => set('leak', v)} />
        <Slider label="lrate target" value={params.lrateTarg} min={0} max={0.2} step={0.001} onChange={(v) => set('lrateTarg', v)} />
        <Slider label="lrate weight" value={params.lrateWmat} min={0} max={1} step={0.01} onChange={(v) => set('lrateWmat', v)} />
        <Slider label="threshold ×" value={params.thresholdMult} min={1} max={4} step={0.1} onChange={(v) => set('thresholdMult', v)} />
        <Slider label="input weight" value={params.inputWeight} min={0} max={6} step={0.05} onChange={(v) => set('inputWeight', v)} />
        <Slider label="weight std" value={params.weightInitStd} min={0.1} max={3} step={0.05} onChange={(v) => set('weightInitStd', v)} />
        <Slider label="link p" value={params.linkP} min={0.02} max={0.5} step={0.01} onChange={(v) => set('linkP', v)} />
        <Slider
          label="N nodes"
          value={params.N}
          min={50}
          max={2000}
          step={10}
          format={(v) => String(Math.round(v))}
          onChange={(v) => set('N', Math.round(v))}
        />
      </div>

      <div className="h-px bg-grid" />

      <div className="flex flex-col gap-2">
        <Toggle label="learn weights" checked={params.learnWeights} onChange={(v) => set('learnWeights', v)} />
        <Toggle label="learn targets" checked={params.learnTargets} onChange={(v) => set('learnTargets', v)} />
        <Toggle label="rectify (≥0)" checked={params.rectify} onChange={(v) => set('rectify', v)} />
      </div>
    </div>
  );
}
