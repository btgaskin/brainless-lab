import { Slider } from './ui/Slider';
import type { SornParams } from '../../simulation/types';

export interface SornControlPanelProps {
  params: SornParams;
  isDefault: boolean;
  onParamsChange: (params: SornParams) => void;
  onRestoreDefault: () => void;
}

export function SornControlPanel({
  params,
  isDefault,
  onParamsChange,
  onRestoreDefault,
}: SornControlPanelProps) {
  const set = <K extends keyof SornParams>(key: K, value: SornParams[K]) =>
    onParamsChange({ ...params, [key]: value });

  return (
    <div className="flex flex-col gap-2 p-3">
      <div className="flex items-center justify-between gap-2">
        <span className="font-mono text-[9px] uppercase tracking-wide text-ink-muted">SORN settings</span>
        <button
          type="button"
          disabled={isDefault}
          onClick={onRestoreDefault}
          className="text-[10px] text-teal-ink underline decoration-grid underline-offset-2 transition-colors hover:text-teal focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-teal disabled:cursor-default disabled:no-underline disabled:opacity-40"
        >
          Restore default
        </button>
      </div>

      <div className="flex flex-col gap-1.5">
        <Slider
          label="N nodes"
          value={params.N}
          min={50}
          max={300}
          step={10}
          format={(value) => String(Math.round(value))}
          onChange={(value) => set('N', Math.round(value))}
        />
        <Slider label="inhibitory fraction" value={params.inhibitoryFraction} min={0.05} max={0.5} step={0.01} format={fmt2} onChange={(value) => set('inhibitoryFraction', value)} />
        <Slider label="E→E connection p" value={params.pEe} min={0.02} max={0.5} step={0.01} format={fmt2} onChange={(value) => set('pEe', value)} />
        <Slider label="STDP rate" value={params.etaStdp} min={0} max={0.02} step={0.0005} format={fmt4} onChange={(value) => set('etaStdp', value)} />
        <Slider label="threshold rate" value={params.etaIp} min={0} max={0.01} step={0.0002} format={fmt4} onChange={(value) => set('etaIp', value)} />
        <Slider label="target activity" value={params.hIp} min={0.01} max={0.5} step={0.01} format={fmt2} onChange={(value) => set('hIp', value)} />
      </div>

      <div className="h-px bg-grid" />

      <button
        type="button"
        role="switch"
        aria-checked={params.learnOn}
        onClick={() => set('learnOn', !params.learnOn)}
        className={`w-fit rounded-full border px-2 py-0.5 font-mono text-[9px] transition-colors active:translate-y-px ${
          params.learnOn
            ? 'border-teal/40 bg-teal-wash text-teal-ink'
            : 'border-grid bg-transparent text-ink-muted hover:text-ink-soft'
        }`}
      >
        plasticity {params.learnOn ? 'on' : 'off'}
      </button>

      <div className="h-px bg-grid" />

      <p className="text-[10px] font-light leading-relaxed text-ink-muted">
        Browser reimplementation of the registered SORN defaults; experimental and illustrative.{' '}
        <a href="/handbook/nodes-reservoirs/#experimental-sorn-node" className="text-teal-ink underline underline-offset-2 hover:text-teal">
          Node boundary&nbsp;→
        </a>
      </p>
    </div>
  );
}

function fmt2(value: number): string {
  return value.toFixed(2);
}

function fmt4(value: number): string {
  return value.toFixed(4);
}
