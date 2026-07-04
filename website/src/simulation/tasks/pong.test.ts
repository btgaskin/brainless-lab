import { describe, expect, it } from 'vitest';
import { PongEnv } from './pong';

describe('PongEnv', () => {
  it('keeps the paddle clamped within the arena under extreme effector inputs', () => {
    const env = new PongEnv(0);
    for (let i = 0; i < 50; i++) env.step([1, 0]); // slam up
    expect(env.snapshot().paddleY).toBeGreaterThanOrEqual(0);

    for (let i = 0; i < 50; i++) env.step([0, 1]); // slam down
    const snap = env.snapshot();
    expect(snap.paddleY).toBeLessThanOrEqual(snap.arenaH - snap.paddleH);
  });

  it('resets the ball to the right side after a miss', () => {
    const env = new PongEnv(0);
    // Slam the paddle to y=0 and keep it there so the ball (which starts
    // centered) is guaranteed to miss on its first approach. A reset shows up
    // as ballX jumping back up near the right wall in a single tick, since a
    // normal tick only moves the ball by BALL_SPEED=5.
    let prevX = env.snapshot().ballX;
    let sawReset = false;
    for (let i = 0; i < 300; i++) {
      env.step([0, 1]);
      const x = env.snapshot().ballX;
      if (x - prevX > 100) sawReset = true;
      prevX = x;
    }
    expect(sawReset).toBe(true);
  });

  it('produces exactly one active sensor bin at a time (or zero if out of range)', () => {
    const env = new PongEnv(0);
    const active = Array.from(env.sense()).filter((v) => v === 1).length;
    expect(active).toBeLessThanOrEqual(1);
  });
});
