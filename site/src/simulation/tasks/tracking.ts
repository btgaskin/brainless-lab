import { Rng } from '../rng';
import type { TaskEnv } from '../types';

/**
 * Object tracking aligned with the registered task defaults: random heading,
 * target, and direction; a 1-degree world step; and a direction change after
 * each 720-tick interval. Two eyes carry 31 Gaussian-tuned sensors each.
 */
const EYE_OFFSETS_DEG = [30, -30];
const SENSOR_OFFSETS_DEG = rangeStep(-60, 60, 4); // 31 values
const EFFECTOR_GAIN_DEG = 10;
const STIMULUS_SPEED_DEG = 1;
const STIMULUS_FLIP_EVERY = 720;
export interface TrackingSnapshot {
  headingDeg: number;
  stimulusDeg: number;
}

export class TrackingEnv implements TaskEnv<TrackingSnapshot> {
  readonly nReceptors = EYE_OFFSETS_DEG.length * SENSOR_OFFSETS_DEG.length; // 62
  readonly nEffectors = 2;

  private headingDeg: number;
  private stimulusDeg: number;
  private stimulusDir: number;
  private readonly initialHeadingDeg: number;
  private readonly initialStimulusDeg: number;
  private readonly initialStimulusDir: number;
  private tick = 0;

  constructor(seed = 0) {
    const rng = new Rng(seed);
    this.initialHeadingDeg = 360 * rng.uniform();
    this.initialStimulusDeg = 360 * rng.uniform();
    this.initialStimulusDir = rng.uniform() < 0.5 ? -1 : 1;
    this.headingDeg = this.initialHeadingDeg;
    this.stimulusDeg = this.initialStimulusDeg;
    this.stimulusDir = this.initialStimulusDir;
  }

  reset(): void {
    this.headingDeg = this.initialHeadingDeg;
    this.stimulusDeg = this.initialStimulusDeg;
    this.stimulusDir = this.initialStimulusDir;
    this.tick = 0;
  }

  sense(): Float64Array {
    const out = new Float64Array(this.nReceptors);
    let idx = 0;
    for (const eyeOffset of EYE_OFFSETS_DEG) {
      for (const sensorOffset of SENSOR_OFFSETS_DEG) {
        const sensorDeg = this.headingDeg + eyeOffset + sensorOffset;
        const delta = wrapDeg(sensorDeg - this.stimulusDeg);
        out[idx] = Math.abs(delta) <= 4 ? 1 : Math.exp(-(delta * delta) / 10);
        idx += 1;
      }
    }
    return out;
  }

  step(effectors: number[]): void {
    const [left, right] = effectors;
    this.headingDeg = wrapDeg(this.headingDeg + EFFECTOR_GAIN_DEG * (left - right));

    this.stimulusDeg = wrapDeg(this.stimulusDeg + this.stimulusDir * STIMULUS_SPEED_DEG);
    this.tick += 1;
    if (this.tick % STIMULUS_FLIP_EVERY === 0) this.stimulusDir *= -1;
  }

  snapshot(): TrackingSnapshot {
    return { headingDeg: this.headingDeg, stimulusDeg: this.stimulusDeg };
  }

}

function rangeStep(start: number, stop: number, step: number): number[] {
  const out: number[] = [];
  for (let v = start; v <= stop + 1e-9; v += step) out.push(v);
  return out;
}

/** Match Julia's wrap to [-180, 180). */
function wrapDeg(deg: number): number {
  return ((deg + 180) % 360 + 360) % 360 - 180;
}
