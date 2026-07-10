import { Slider } from './ui/Slider';
import type { FalandaysParams } from '../../simulation/types';

export interface ControlPanelProps {
  params: FalandaysParams;
  onParamsChange: (params: FalandaysParams) => void;
}

function Chip({ label, checked, onChange }: { label: string; checked: boolean; onChange: (checked: boolean) => void }) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      onClick={() => onChange(!checked)}
      className={`rounded-full border px-2 py-0.5 font-mono text-[9px] transition-colors active:translate-y-px ${
        checked
          ? 'border-teal/40 bg-teal-wash text-teal-ink'
          : 'border-grid bg-transparent text-ink-muted hover:text-ink-soft'
      }`}
    >
      {label}
    </button>
  );
}

/**
 * The parameter column — sliders + learning-rule chips only. Transport
 * (play/step/reset) and the task switcher live in SimDemo's toolbar, which
 * keeps this column short enough to fit beside the canvas without clipping.
 * Same palette as the rest of the site (src/viz/Style.jl: paper/ink/teal/amber).
 */
export function ControlPanel({ params, onParamsChange }: ControlPanelProps) {
  const set = <K extends keyof FalandaysParams>(key: K, value: FalandaysParams[K]) =>
    onParamsChange({ ...params, [key]: value });

  return (
    <div className="flex flex-col gap-2 p-3">
      <div className="flex flex-col gap-1.5">
        <Slider label="target floor" value={params.targetFloor} min={0.2} max={3} step={0.05} format={fmt2} onChange={(v) => set('targetFloor', v)} />
        <Slider label="leak" value={params.leak} min={0} max={0.9} step={0.01} format={fmt2} onChange={(v) => set('leak', v)} />
        <Slider label="lrate target" value={params.lrateTarg} min={0} max={0.2} step={0.001} onChange={(v) => set('lrateTarg', v)} />
        <Slider label="lrate weight" value={params.lrateWmat} min={0} max={1} step={0.01} format={fmt2} onChange={(v) => set('lrateWmat', v)} />
        <Slider label="threshold ×" value={params.thresholdMult} min={1} max={4} step={0.1} format={fmt2} onChange={(v) => set('thresholdMult', v)} />
        <Slider label="input weight" value={params.inputWeight} min={0} max={6} step={0.05} format={fmt2} onChange={(v) => set('inputWeight', v)} />
        <Slider label="weight std" value={params.weightInitStd} min={0.1} max={3} step={0.05} format={fmt2} onChange={(v) => set('weightInitStd', v)} />
        <Slider label="link p" value={params.linkP} min={0.02} max={0.5} step={0.01} format={fmt2} onChange={(v) => set('linkP', v)} />
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

      <div className="flex flex-wrap items-center gap-1.5">
        <Chip label="learn w" checked={params.learnWeights} onChange={(v) => set('learnWeights', v)} />
        <Chip label="learn targets" checked={params.learnTargets} onChange={(v) => set('learnTargets', v)} />
      </div>

      <div className="h-px bg-grid" />

      {/* Attribution footnote for the landing demo — kept light and unobtrusive. */}
      <p className="text-[10px] font-light leading-relaxed text-ink-muted">
        Untrained homeostatic spiking neurons after Falandays&nbsp;et&nbsp;al. (2024), adapting
        online. The lab asks why this model works.{' '}
        <a href="/nodes/falandays/" className="text-teal-ink underline underline-offset-2 hover:text-teal">
          Falandays node&nbsp;→
        </a>
        <br />
        Browser reimplementation with aligned task constants; not a bit-level Julia replay.
      </p>
    </div>
  );
}

function fmt2(v: number): string {
  return v.toFixed(2);
}
