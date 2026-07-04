export interface ReadoutStripProps {
  meanActivation: number;
  meanAbsError: number;
  meanTarget: number;
  spikeCount: number;
  nNodes: number;
  effectorOutputs: number[];
  tick: number;
  taskScore?: { label: string; value: number };
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex flex-col gap-0.5">
      <span className="font-mono text-[10px] uppercase tracking-wide text-ink-muted">{label}</span>
      <span className="font-mono text-sm text-ink">{value}</span>
    </div>
  );
}

/** Live numbers, updated at a throttled rate (~10Hz in the real loop), never per-frame. */
export function ReadoutStrip({ meanActivation, meanAbsError, meanTarget, spikeCount, nNodes, effectorOutputs, tick, taskScore }: ReadoutStripProps) {
  return (
    <div className="flex flex-wrap gap-6 border-t border-grid bg-card px-4 py-3">
      <Stat label="tick" value={String(tick)} />
      <Stat label="mean act" value={meanActivation.toFixed(3)} />
      <Stat label="mean |err|" value={meanAbsError.toFixed(3)} />
      <Stat label="mean target" value={meanTarget.toFixed(3)} />
      <Stat label="spiking" value={`${spikeCount} / ${nNodes}`} />
      <Stat label="effectors" value={effectorOutputs.map((e) => e.toFixed(2)).join(', ')} />
      {taskScore ? <Stat label={taskScore.label} value={taskScore.value.toFixed(3)} /> : null}
    </div>
  );
}
