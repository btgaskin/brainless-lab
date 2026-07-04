import { Rng } from '../rng';
import type { TaskEnv } from '../types';

/**
 * Wall-avoidance, ported from the paper's case study 3 (Braitenberg-style
 * two-wheeled agent, 15x15m box) and cross-checked against src/envs/WallBox.jl
 * — both agree exactly on: +/-45deg ray-cast sensors, d_max = sqrt(2*15^2),
 * v=(eL+eR)/2 forward speed along the old heading, dtheta=(eR-eL)/(2r),
 * clamp-and-slide wall contact, and random +/-45deg turn after the step turn.
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
  private headingRad = Math.PI / 2;
  private collided = false;
  private readonly rng: Rng;

  constructor(seed = 0) {
    this.rng = new Rng(seed);
  }

  reset(): void {
    this.x = BOX_SIZE / 2;
    this.y = BOX_SIZE / 2;
    this.headingRad = Math.PI / 2;
    this.collided = false;
  }

  private raycast(offsetRad: number): number {
    const a = this.headingRad + offsetRad;
    const dx = Math.cos(a);
    const dy = Math.sin(a);
    const ox = this.x + AGENT_RADIUS * dx;
    const oy = this.y + AGENT_RADIUS * dy;
    let t = Infinity;
    if (dx > 0) t = Math.min(t, (BOX_SIZE - ox) / dx);
    else if (dx < 0) t = Math.min(t, -ox / dx);
    if (dy > 0) t = Math.min(t, (BOX_SIZE - oy) / dy);
    else if (dy < 0) t = Math.min(t, -oy / dy);
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
    const theta0 = this.headingRad;
    const dtheta = (eR - eL) / (2 * AGENT_RADIUS);
    const nx = this.x + v * Math.cos(this.headingRad);
    const ny = this.y + v * Math.sin(this.headingRad);
    const cx = clamp(nx, AGENT_RADIUS, BOX_SIZE - AGENT_RADIUS);
    const cy = clamp(ny, AGENT_RADIUS, BOX_SIZE - AGENT_RADIUS);

    this.x = cx;
    this.y = cy;
    this.headingRad = theta0 + dtheta;
    this.collided = nx !== cx || ny !== cy;
    if (this.collided) {
      this.collided = true;
      const turn = this.rng.uniform() < 0.5 ? Math.PI / 4 : -Math.PI / 4;
      this.headingRad += turn;
    }
  }

  snapshot(): WallSnapshot {
    return { boxSize: BOX_SIZE, x: this.x, y: this.y, headingRad: this.headingRad, collided: this.collided };
  }
}

function clamp01(x: number): number {
  return x < 0 ? 0 : x > 1 ? 1 : x;
}

function clamp(x: number, lo: number, hi: number): number {
  return x < lo ? lo : x > hi ? hi : x;
}
