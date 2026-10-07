/** Recorded Quadrants output. Validation and display adapters only. */
export interface ReplayCase {
  id: string; task: string; node: 'falandays' | 'sorn'; label: string; path: string;
}
export interface ReplayFrame {
  tick: number; activity: number[]; effectors: number[]; inputs: number[];
  world: Record<string, unknown>;
}
export interface Replay {
  format: 'brainlesslab-replay'; version: 1; task: string; node: 'falandays' | 'sorn';
  provenance: {
    quadrants_version: string; backend: string; dtype: string;
    seed_partition: 'development'; resolved: Record<string, unknown>;
  };
  frames: ReplayFrame[];
}
function object(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}
function numbers(value: unknown): value is number[] {
  return Array.isArray(value) && value.every((v) => typeof v === 'number' && Number.isFinite(v));
}
export function parseIndex(value: unknown): ReplayCase[] {
  if (!object(value) || value.format !== 'brainlesslab-replay-index' || value.version !== 1 || !Array.isArray(value.cases)) {
    throw new Error('The recorded display index has an unsupported format.');
  }
  const cases = value.cases;
  for (const item of cases) {
    if (!object(item) || typeof item.id !== 'string' || !item.id || typeof item.label !== 'string' || !item.label ||
        typeof item.task !== 'string' || !item.task || !['falandays', 'sorn'].includes(String(item.node)) ||
        typeof item.path !== 'string' || !/^\/replays\/[a-z0-9_-]+\.json$/.test(item.path)) {
      throw new Error('The recorded display index contains an invalid case.');
    }
  }
  if (new Set(cases.map((item) => item.id)).size !== cases.length) {
    throw new Error('The recorded display index contains duplicate case IDs.');
  }
  return cases as ReplayCase[];
}
export function parseReplay(value: unknown, selected: ReplayCase): Replay {
  if (!object(value) || value.format !== 'brainlesslab-replay' || value.version !== 1 ||
      value.task !== selected.task || value.node !== selected.node || !object(value.provenance) ||
      value.provenance.seed_partition !== 'development' ||
      typeof value.provenance.quadrants_version !== 'string' || !value.provenance.quadrants_version ||
      !['cpu', 'metal'].includes(String(value.provenance.backend)) ||
      !['float32', 'float64'].includes(String(value.provenance.dtype)) ||
      !object(value.provenance.resolved) || !Array.isArray(value.frames) || !value.frames.length) {
    throw new Error('The selected recording has invalid development provenance or no frames.');
  }
  let previousTick = -1;
  let widths: number[] | undefined;
  for (const frame of value.frames) {
    if (!object(frame) || !Number.isInteger(frame.tick) || Number(frame.tick) <= previousTick ||
        !numbers(frame.activity) || !frame.activity.length || frame.activity.some((value) => value !== 0 && value !== 1) || !numbers(frame.effectors) ||
        !numbers(frame.inputs) || !object(frame.world)) {
      throw new Error('The selected recording contains an invalid frame.');
    }
    const current = [frame.activity.length, frame.effectors.length, frame.inputs.length];
    if (widths && current.some((width, index) => width !== widths![index])) {
      throw new Error('The selected recording changes its neural or port dimensions.');
    }
    widths = current;
    previousTick = Number(frame.tick);
  }
  return value as unknown as Replay;
}
export function nextFrame(index: number, length: number): number {
  return Math.min(index + 1, Math.max(0, length - 1));
}
export function scalar(world: Record<string, unknown>, ...keys: string[]): number | undefined {
  for (const key of keys) {
    const value = world[key];
    if (typeof value === 'number' && Number.isFinite(value)) return value;
  }
}
