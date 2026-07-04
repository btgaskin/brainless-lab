import { Rng } from '../rng';
import type { TaskEnv } from '../types';

/**
 * Pong, ported from the paper's case study 2: 1000x500 arena, ball radius 15,
 * speed 5px/tick both axes, paddle height 100 fixed at x=100. 46 bearing
 * sensors over -90:4:90deg from the paddle centre to the ball; paddle_y +=
 * 100*(oUp-oDown). Cross-checked against src/envs/Envs.jl's PongEnv.
 */
const ARENA_W = 1000;
const ARENA_H = 500;
const BALL_R = 15;
const BALL_SPEED = 5;
const PADDLE_X = 100;
const PADDLE_H = 100;
const PADDLE_R = PADDLE_H / 2;
const CATCH_R = PADDLE_R + BALL_R;
const SENSOR_OFFSETS_DEG = rangeStep(-90, 90, 4); // 46 values
const EFFECTOR_GAIN = 100;
const RESET_X = 995;
const MIN_BALL_Y = 1;
const MAX_BALL_Y = 499;
const BOUNCE_MIN_Y = 5;
const BOUNCE_MAX_Y = 495;

export interface PongSnapshot {
  arenaW: number;
  arenaH: number;
  ballR: number;
  paddleX: number;
  paddleH: number;
  catchR: number;
  ballX: number;
  ballY: number;
  /** Paddle centre y, matching the authors' Julia agent position. */
  paddleY: number;
  hits: number;
  misses: number;
  hitRate: number;
  score: number;
}

export class PongEnv implements TaskEnv<PongSnapshot> {
  readonly nReceptors = SENSOR_OFFSETS_DEG.length;
  readonly nEffectors = 2;

  private ballX = RESET_X;
  private ballY = ARENA_H / 2;
  private ballVx = -BALL_SPEED;
  private ballVy = BALL_SPEED;
  private paddleY = ARENA_H / 2;
  private pastPaddle = false;
  private hits = 0;
  private misses = 0;
  private readonly rng: Rng;

  constructor(seed = 0) {
    this.rng = new Rng(seed);
    this.resetBall();
  }

  reset(): void {
    this.paddleY = ARENA_H / 2;
    this.hits = 0;
    this.misses = 0;
    this.resetBall();
  }

  sense(): Float64Array {
    const out = new Float64Array(this.nReceptors);
    const bearingDeg = (Math.atan2(this.ballY - this.paddleY, this.ballX - PADDLE_X) * 180) / Math.PI;
    if (bearingDeg >= -90 && bearingDeg <= 90) {
      for (let k = 0; k < SENSOR_OFFSETS_DEG.length; k++) {
        out[k] = Math.abs(wrapDeg(bearingDeg - SENSOR_OFFSETS_DEG[k])) <= 2 ? 1 : 0;
      }
    }
    return out;
  }

  step(effectors: number[]): void {
    const [up, down] = effectors;
    this.paddleY += EFFECTOR_GAIN * (up - down);
    if (this.paddleY < PADDLE_R) this.paddleY = PADDLE_R;
    if (this.paddleY > ARENA_H - PADDLE_R) this.paddleY = ARENA_H - PADDLE_R;

    this.ballX += this.ballVx;
    this.ballY += this.ballVy;

    if (this.ballY <= BOUNCE_MIN_Y) {
      this.ballY = BOUNCE_MIN_Y;
      this.ballVy = Math.abs(this.ballVy);
    } else if (this.ballY >= BOUNCE_MAX_Y) {
      this.ballY = BOUNCE_MAX_Y;
      this.ballVy = -Math.abs(this.ballVy);
    }

    if (this.ballX >= RESET_X) {
      this.ballX = RESET_X;
      this.ballVx = -Math.abs(this.ballVx);
      this.pastPaddle = false;
    }

    if (this.ballVx < 0 && !this.pastPaddle && this.ballX <= PADDLE_X + BALL_R) {
      if (Math.abs(this.ballY - this.paddleY) <= CATCH_R) {
        this.ballX = PADDLE_X + BALL_R;
        this.ballVx = Math.abs(this.ballVx);
        this.hits += 1;
      } else {
        this.pastPaddle = true;
      }
    }

    if (this.ballX < 0) {
      this.misses += 1;
      this.resetBall();
    }
  }

  snapshot(): PongSnapshot {
    const events = this.hits + this.misses;
    const hitRate = events === 0 ? 0 : this.hits / events;
    return {
      arenaW: ARENA_W,
      arenaH: ARENA_H,
      ballR: BALL_R,
      paddleX: PADDLE_X,
      paddleH: PADDLE_H,
      catchR: CATCH_R,
      ballX: this.ballX,
      ballY: this.ballY,
      paddleY: this.paddleY,
      hits: this.hits,
      misses: this.misses,
      hitRate,
      score: hitRate,
    };
  }

  private resetBall(): void {
    this.ballX = RESET_X;
    this.ballY = MIN_BALL_Y + this.rng.uniform() * (MAX_BALL_Y - MIN_BALL_Y);
    this.ballVx = -BALL_SPEED;
    this.ballVy = this.rng.uniform() < 0.5 ? BALL_SPEED : -BALL_SPEED;
    this.pastPaddle = false;
  }
}

function rangeStep(start: number, stop: number, step: number): number[] {
  const out: number[] = [];
  for (let v = start; v <= stop + 1e-9; v += step) out.push(v);
  return out;
}

function wrapDeg(deg: number): number {
  let d = deg % 360;
  if (d > 180) d -= 360;
  if (d <= -180) d += 360;
  return d;
}
