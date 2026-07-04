import { describe, expect, it } from 'vitest';
import { WallEnv } from './wall';

describe('WallEnv', () => {
  it('reports ray-cast sensor values within (eps, 1]', () => {
    const env = new WallEnv(0);
    const r = env.sense();
    for (const v of r) {
      expect(v).toBeGreaterThan(0);
      expect(v).toBeLessThanOrEqual(1);
    }
  });

  it('turns randomly instead of moving through a wall on collision', () => {
    const env = new WallEnv(0);
    const before = env.snapshot();
    // full-speed straight ahead, repeatedly, until it must hit a wall
    let collided = false;
    for (let i = 0; i < 200; i++) {
      env.step([1, 1]);
      if (env.snapshot().collided) {
        collided = true;
        break;
      }
    }
    expect(collided).toBe(true);
    // heading must have changed (the random turn), position frozen that tick
    expect(env.snapshot().headingRad).not.toBe(before.headingRad);
  });

  it('clamps effector inputs outside [0,1] before using them', () => {
    const env = new WallEnv(0);
    expect(() => env.step([5, -5])).not.toThrow();
  });
});
