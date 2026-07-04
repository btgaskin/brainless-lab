import { motion } from 'motion/react';

const STEPS = [
  {
    title: 'Integrate & leak',
    eq: 'x = x·(1−leak) + inputWeight·R + W_rec · prevSpikes',
  },
  {
    title: 'Spike & reset',
    eq: 'spike = x ≥ thresholdMult·target;  if spiking: x −= thresholdMult·target',
  },
  {
    title: 'Homeostatic update',
    eq: 'error = x − target;  target ← max(floor, target + lrateTarg·error);  w −= (error / nSpikingNeighbors)·lrateWmat',
  },
] as const;

export interface UpdateLoopDiagramProps {
  /** Which step is currently executing, or null when the sim is paused. */
  activeStep: 0 | 1 | 2 | null;
}

/** The 3-step update flowchart, equation per step, active step highlighted in sync with the sim clock. */
export function UpdateLoopDiagram({ activeStep }: UpdateLoopDiagramProps) {
  return (
    <div className="grid grid-cols-1 gap-2 sm:grid-cols-3">
      {STEPS.map((step, i) => {
        const active = activeStep === i;
        return (
          <motion.div
            key={step.title}
            className="rounded-lg border p-4"
            animate={{
              borderColor: active ? '#2f6f5e' : '#dedad0',
              backgroundColor: active ? 'rgba(47,111,94,0.08)' : '#ffffff',
            }}
            transition={{ type: 'spring', stiffness: 120, damping: 20 }}
          >
            <div className="font-mono text-[10px] uppercase tracking-wide text-ink-muted">Step {i + 1}</div>
            <div className="mt-1 font-sans text-sm text-ink">{step.title}</div>
            <div className="mt-2 font-mono text-[11px] leading-snug text-ink-soft">{step.eq}</div>
          </motion.div>
        );
      })}
    </div>
  );
}
