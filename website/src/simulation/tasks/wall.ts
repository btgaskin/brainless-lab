import { Rng } from '../rng';
import type { TaskEnv } from '../types';

/**
 * Wall-avoidance, ported from the paper's case study 3 (Braitenberg-style
 * two-wheeled agent, 15x15m box) and cross-checked against src/envs/WallBox.jl
 * — both agree exactly on: +/-45deg ray-cast sensors, d_max = sqrt(2*15^2),
 * v=(eL+eR)/2 forward speed, dtheta=eR-eL heading change, random +/-45deg turn
 * on wall contact instead of moving through it.
 */
const BOX_SIZE = 15;
const AGENT_RADIUS = 0.5;
const D_MAX = Math.sqrt(2 * BOX_SIZE * BOX_SIZE);
const SENSOR_OFFSETS_RAD = [45, -45].map((d) => (d * Math.PI) / 180);
const EPS = 1e-6;

export interface WallSnapshot {
  boxSize: number;
  x: number;
  y: number;
  headingRad: number;
  collided: boolean;
}

export class WallEnv implements TaskEnv<WallSnapshot> {
  readonly nReceptors = 2;
  readonly nEffectors = 2;

  private x = BOX_SIZE / 2;
  private y = BOX_SIZE / 2;
  private headingRad = 0;
  private collided = false;
  private readonly rng: Rng;

  constructor(seed = 0) {
    this.rng = new Rng(seed);
  }

  reset(): void {
    this.x = BOX_SIZE / 2;
    this.y = BOX_SIZE / 2;
    this.headingRad = 0;
    this.collided = false;
  }

  private raycast(offsetRad: number): number {
    const a = this.headingRad + offsetRad;
    const dx = Math.cos(a);
    const dy = Math.sin(a);
    let t = Infinity;
    if (dx > 0) t = Math.min(t, (BOX_SIZE - this.x) / dx);
    else if (dx < 0) t = Math.min(t, -this.x / dx);
    if (dy > 0) t = Math.min(t, (BOX_SIZE - this.y) / dy);
    else if (dy < 0) t = Math.min(t, -this.y / dy);
    return Math.max(0, t);
  }

  sense(): Float64Array {
    const out = new Float64Array(2);
    for (let k = 0; k < 2; k++) {
      const d = this.raycast(SENSOR_OFFSETS_RAD[k]);
      let v = 1 - d / D_MAX;
      if (v < EPS) v = EPS;
      if (v > 1) v = 1;
      out[k] = v;
    }
    return out;
  }

  step(effectors: number[]): void {
    const eL = clamp01(effectors[0]);
    const eR = clamp01(effectors[1]);
    const v = (eL + eR) / 2;
    const dtheta = eR - eL;
    const nx = this.x + v * Math.cos(this.headingRad);
    const ny = this.y + v * Math.sin(this.headingRad);

    const outOfBounds = nx < AGENT_RADIUS || nx > BOX_SIZE - AGENT_RADIUS || ny < AGENT_RADIUS || ny > BOX_SIZE - AGENT_RADIUS;
    if (outOfBounds) {
      this.collided = true;
      const turn = this.rng.uniform() < 0.5 ? Math.PI / 4 : -Math.PI / 4;
      this.headingRad += turn;
    } else {
      this.collided = false;
      this.x = nx;
      this.y = ny;
      this.headingRad += dtheta;
    }
  }

  snapshot(): WallSnapshot {
    return { boxSize: BOX_SIZE, x: this.x, y: this.y, headingRad: this.headingRad, collided: this.collided };
  }
}

function clamp01(x: number): number {
  return x < 0 ? 0 : x > 1 ? 1 : x;
}
