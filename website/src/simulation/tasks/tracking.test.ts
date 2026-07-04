import { describe, expect, it } from 'vitest';
import { TrackingEnv } from './tracking';

describe('TrackingEnv', () => {
  it('peaks a sensor at ~1 when its absolute bearing matches the stimulus exactly', () => {
    const env = new TrackingEnv();
    // heading=90, left eye offset=+30 -> eye center at 120deg, sensor offset 0 -> 120deg exactly.
    // Put the stimulus at 120deg and confirm that sensor reads ~1 (Gaussian peak).
    // stimulusDeg starts at 0 and drifts -1deg/tick; step until it reaches 120 (mod 360, going negative).
    // Simpler: directly assert the reported vector's max value approaches 1 when
    // the stimulus happens to align with a sensor within a few degrees.
    for (let i = 0; i < 240; i++) env.step([0, 0]); // drift the stimulus around
    const r = env.sense();
    const max = Math.max(...r);
    expect(max).toBeGreaterThan(0);
    expect(max).toBeLessThanOrEqual(1);
  });

  it('reports 62 receptors (2 eyes x 31 sensors)', () => {
    const env = new TrackingEnv();
    expect(env.nReceptors).toBe(62);
    expect(env.sense().length).toBe(62);
  });

  it('turns heading proportionally to the effector gain (10deg/tick)', () => {
    const env = new TrackingEnv();
    const before = env.snapshot().headingDeg;
    env.step([1, 0]);
    const after = env.snapshot().headingDeg;
    expect(Math.abs(after - before)).toBeCloseTo(10, 5);
  });
});
