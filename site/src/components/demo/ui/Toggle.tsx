import { motion } from 'motion/react';

interface ToggleProps {
  label: string;
  checked: boolean;
  onChange: (checked: boolean) => void;
}

export function Toggle({ label, checked, onChange }: ToggleProps) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      onClick={() => onChange(!checked)}
      className="flex w-full items-center justify-between gap-3 rounded-md py-1 text-left active:translate-y-px"
    >
      <span className="font-mono text-[11px] text-ink-soft">{label}</span>
      <span
        className="relative inline-flex h-4 w-8 shrink-0 items-center rounded-full transition-colors"
        style={{ backgroundColor: checked ? '#2f6f5e' : '#dedad0' }}
      >
        <motion.span
          className="inline-block h-3 w-3 rounded-full bg-card"
          animate={{ x: checked ? 17 : 3 }}
          transition={{ type: 'spring', stiffness: 400, damping: 30 }}
        />
      </span>
    </button>
  );
}
