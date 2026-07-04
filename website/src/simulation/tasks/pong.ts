import { Rng } from '../rng';
import type { TaskEnv } from '../types';

/**
 * Pong, ported from the paper's case study 2: 1000x500 arena, ball radius 15,
 * speed 5px/tick both axes, paddle height 100 fixed at x=100. 46 bearing
 * sensors over -90:4:90deg from the paddle to the ball; paddle_y +=
 * 100*(oUp-oDown). Cross-checked against src/envs/Envs.jl's PongEnv, which
 * agrees on every constant here.
 */
const ARENA_W = 1000;
const ARENA_H = 500;
const BALL_R = 15;
const BALL_SPEED = 5;
const PADDLE_X = 100;
const PADDLE_H = 100;
const SENSOR_OFFSETS_DEG = rangeStep(-90, 90, 4); // 46 values
const EFFECTOR_GAIN = 100;

export interface PongSnapshot {
  arenaW: number;
  arenaH: number;
  ballR: number;
  paddleX: number;
  paddleH: number;
  ballX: number;
  ballY: number;
  paddleY: number;
}

export class PongEnv implements TaskEnv<PongSnapshot> {
  readonly nReceptors = SENSOR_OFFSETS_DEG.length;
  readonly nEffectors = 2;

  private ballX = ARENA_W - 50;
  private ballY = ARENA_H / 2;
  private ballVx = -BALL_SPEED;
  private ballVy = BALL_SPEED;
  private paddleY = (ARENA_H - PADDLE_H) / 2;
  private readonly rng: Rng;

  constructor(seed = 0) {
    this.rng = new Rng(seed);
  }

  reset(): void {
    this.ballX = ARENA_W - 50;
    this.ballY = ARENA_H / 2;
    this.ballVx = -BALL_SPEED;
    this.ballVy = BALL_SPEED;
    this.paddleY = (ARENA_H - PADDLE_H) / 2;
  }

  sense(): Float64Array {
    const out = new Float64Array(this.nReceptors);
    const cx = PADDLE_X;
    const cy = this.paddleY + PADDLE_H / 2;
    const bearingDeg = (Math.atan2(this.ballY - cy, this.ballX - cx) * 180) / Math.PI;
    for (let k = 0; k < SENSOR_OFFSETS_DEG.length; k++) {
      const lo = SENSOR_OFFSETS_DEG[k] - 2;
      const hi = SENSOR_OFFSETS_DEG[k] + 2;
      out[k] = bearingDeg >= lo && bearingDeg < hi ? 1 : 0;
    }
    return out;
  }

  step(effectors: number[]): void {
    const [up, down] = effectors;
    this.paddleY += EFFECTOR_GAIN * (up - down);
    if (this.paddleY < 0) this.paddleY = 0;
    if (this.paddleY > ARENA_H - PADDLE_H) this.paddleY = ARENA_H - PADDLE_H;

    this.ballX += this.ballVx;
    this.ballY += this.ballVy;

    if (this.ballY <= BALL_R || this.ballY >= ARENA_H - BALL_R) this.ballVy *= -1;
    if (this.ballX >= ARENA_W - BALL_R) this.ballVx *= -1;

    const hitsPaddle =
      this.ballVx < 0 &&
      this.ballX - BALL_R <= PADDLE_X &&
      this.ballY >= this.paddleY &&
      this.ballY <= this.paddleY + PADDLE_H;
    if (hitsPaddle) {
      this.ballVx *= -1;
    } else if (this.ballX < 0) {
      // missed — reset to the right side with a random y-position and y-direction
      this.ballX = ARENA_W - 50;
      this.ballY = this.rng.uniform() * ARENA_H;
      this.ballVx = -BALL_SPEED;
      this.ballVy = this.rng.uniform() < 0.5 ? BALL_SPEED : -BALL_SPEED;
    }
  }

  snapshot(): PongSnapshot {
    return {
      arenaW: ARENA_W,
      arenaH: ARENA_H,
      ballR: BALL_R,
      paddleX: PADDLE_X,
      paddleH: PADDLE_H,
      ballX: this.ballX,
      ballY: this.ballY,
      paddleY: this.paddleY,
    };
  }
}

function rangeStep(start: number, stop: number, step: number): number[] {
  const out: number[] = [];
  for (let v = start; v <= stop + 1e-9; v += step) out.push(v);
  return out;
}
