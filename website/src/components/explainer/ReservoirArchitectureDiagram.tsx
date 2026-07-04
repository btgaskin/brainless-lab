/**
 * Static schematic of the reservoir's structure — the sensorimotor contract
 * (percept -> receptors -> R -> step! -> spikes -> effectors -> E -> motor),
 * not a per-node render. Deliberately not wired to live sim state: this is
 * page/explainer content, decoupled from the ticking SimDemo component.
 */
const STAGES = [
  { label: 'Percept', detail: 'world state' },
  { label: 'Receptors', detail: 'R — sensory input vector' },
  { label: 'Reservoir', detail: 'homeostatic spiking network' },
  { label: 'Effectors', detail: 'E — motor output vector' },
  { label: 'Actuation', detail: 'changes the world' },
] as const;

export function ReservoirArchitectureDiagram() {
  return (
    <div className="flex flex-wrap items-stretch gap-2 rounded-lg border border-grid bg-card p-4 font-mono">
      {STAGES.map((stage, i) => (
        <div key={stage.label} className="flex items-stretch gap-2">
          <div className="flex min-w-[132px] flex-col justify-center gap-1 rounded-md border border-grid bg-paper px-3 py-2">
            <span className="text-sm text-ink">{stage.label}</span>
            <span className="text-[10px] text-ink-muted">{stage.detail}</span>
          </div>
          {i < STAGES.length - 1 && (
            <span className="flex items-center text-teal" aria-hidden="true">
              &rarr;
            </span>
          )}
        </div>
      ))}
    </div>
  );
}
