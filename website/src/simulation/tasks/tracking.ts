import type { TaskEnv } from '../types';

/**
 * Object-tracking, ported from the paper's case study 1: agent fixed in
 * place, only rotates; a stimulus circles it at radius 1, 1deg/tick, flipping
 * direction every 720 ticks. Two eyes at +/-30deg from heading, each 31
 * Gaussian-tuned sensors over -60:4:60deg — matches src/envs/Envs.jl's
 * TrackingEnv exactly (already cross-verified in the earlier docs review).
 */
const EYE_OFFSETS_DEG = [30, -30];
const SENSOR_OFFSETS_DEG = rangeStep(-60, 60, 4); // 31 values
const EFFECTOR_GAIN_DEG = 10;
const STIMULUS_SPEED_DEG = 1;
const STIMULUS_FLIP_EVERY = 720;
const INITIAL_HEADING_DEG = 90;
/**
 * The Gaussian tuning (exp(-delta^2/10)) is narrow — meaningful signal only
 * within roughly +/-8deg of a sensor's preferred angle, well inside the
 * paper's nominal +/-60deg eye field-of-view. Starting the stimulus at the
 * paper's own initial position (0deg, ~90deg from the nearest eye center)
 * is faithful to the paper's description of an undirected ~100-tick search
 * before lock-on, but reads as "broken" in a short interactive demo. Instead
 * start it just outside the left eye's cone, on the side its initial
 * direction of travel (stimulusDir=-1, decreasing angle) sweeps in from, so
 * tracking visibly begins within a few ticks instead of ~100.
 *
 * "Left eye" here is screen-left in trackingRenderer's canvas convention
 * (heading=90deg points down the canvas; offset +30deg -> cos(120deg)<0,
 * i.e. left of center), which is EYE_OFFSETS_DEG[0] (+30), not [1] (-30).
 */
const LEFT_EYE_OFFSET_DEG = EYE_OFFSETS_DEG[0];
const START_MARGIN_DEG = 6;
const INITIAL_STIMULUS_DEG = INITIAL_HEADING_DEG + LEFT_EYE_OFFSET_DEG + START_MARGIN_DEG;

export interface TrackingSnapshot {
  headingDeg: number;
  stimulusDeg: number;
}

export class TrackingEnv implements TaskEnv<TrackingSnapshot> {
  readonly nReceptors = EYE_OFFSETS_DEG.length * SENSOR_OFFSETS_DEG.length; // 62
  readonly nEffectors = 2;

  private headingDeg = INITIAL_HEADING_DEG;
  private stimulusDeg = INITIAL_STIMULUS_DEG;
  private stimulusDir = -1; // paper: starts moving counter-clockwise, toward the nearer eye center

  private tick = 0;

  reset(): void {
    this.headingDeg = INITIAL_HEADING_DEG;
    this.stimulusDeg = INITIAL_STIMULUS_DEG;
    this.stimulusDir = -1;
    this.tick = 0;
  }

  sense(): Float64Array {
    const out = new Float64Array(this.nReceptors);
    let idx = 0;
    for (const eyeOffset of EYE_OFFSETS_DEG) {
      for (const sensorOffset of SENSOR_OFFSETS_DEG) {
        const sensorDeg = this.headingDeg + eyeOffset + sensorOffset;
        const delta = wrapDeg(sensorDeg - this.stimulusDeg);
        out[idx] = Math.exp(-(delta * delta) / 10);
        idx += 1;
      }
    }
    return out;
  }

  step(effectors: number[]): void {
    const [left, right] = effectors;
    this.headingDeg = wrapDeg(this.headingDeg + EFFECTOR_GAIN_DEG * (left - right));

    this.tick += 1;
    if (this.tick % STIMULUS_FLIP_EVERY === 0) this.stimulusDir *= -1;
    this.stimulusDeg = wrapDeg(this.stimulusDeg + this.stimulusDir * STIMULUS_SPEED_DEG);
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

/** Wrap to (-180, 180]. */
function wrapDeg(deg: number): number {
  let d = deg % 360;
  if (d > 180) d -= 360;
  if (d <= -180) d += 360;
  return d;
}
