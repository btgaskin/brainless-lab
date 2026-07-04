interface SliderProps {
  label: string;
  value: number;
  min: number;
  max: number;
  step: number;
  onChange: (value: number) => void;
  format?: (value: number) => string;
}

export function Slider({ label, value, min, max, step, onChange, format }: SliderProps) {
  return (
    <label className="flex flex-col gap-[3px]">
      <span className="flex items-baseline justify-between font-mono text-[9px] uppercase leading-none tracking-wide text-ink-muted">
        <span>{label}</span>
        <span className="tabular-nums text-ink-soft">{(format ?? ((v: number) => v.toFixed(3)))(value)}</span>
      </span>
      <input
        type="range"
        min={min}
        max={max}
        step={step}
        value={value}
        onChange={(e) => onChange(Number(e.target.value))}
        className="bl-range h-3 w-full cursor-pointer"
      />
    </label>
  );
}
