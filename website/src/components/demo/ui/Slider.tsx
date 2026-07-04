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
    <label className="flex flex-col gap-1">
      <span className="flex items-baseline justify-between font-mono text-[10px] uppercase tracking-wide text-ink-muted">
        <span>{label}</span>
        <span className="text-ink-soft">{(format ?? ((v: number) => v.toFixed(3)))(value)}</span>
      </span>
      <input
        type="range"
        min={min}
        max={max}
        step={step}
        value={value}
        onChange={(e) => onChange(Number(e.target.value))}
        className="h-1 w-full cursor-pointer appearance-none rounded-full bg-grid accent-teal"
      />
    </label>
  );
}
