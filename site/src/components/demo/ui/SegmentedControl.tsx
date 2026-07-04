interface SegmentedControlProps<T extends string> {
  options: Array<{ value: T; label: string }>;
  value: T;
  onChange: (value: T) => void;
}

export function SegmentedControl<T extends string>({ options, value, onChange }: SegmentedControlProps<T>) {
  return (
    <div className="grid auto-cols-fr grid-flow-col gap-0.5 rounded-md bg-paper p-0.5">
      {options.map((opt) => (
        <button
          key={opt.value}
          type="button"
          onClick={() => onChange(opt.value)}
          className={`rounded-[4px] px-2 py-1 font-mono text-[11px] transition-colors active:translate-y-px ${
            opt.value === value ? 'bg-card text-ink' : 'text-ink-muted'
          }`}
          style={opt.value === value ? { boxShadow: 'inset 0 0 0 1px #2f6f5e55' } : undefined}
        >
          {opt.label}
        </button>
      ))}
    </div>
  );
}
