import { describe, expect, test } from 'bun:test';
import { nextFrame, parseIndex, parseReplay } from './replay';

// Handwritten test-only data verifies the reader. It is never a public recording.
const selected = { id: 'test-only', task: 'tracking', node: 'sorn' as const, label: 'Test only', path: '/replays/test-only.json' };
const index = { format: 'brainlesslab-replay-index', version: 1, cases: [selected] };
function recording() {
  return { format: 'brainlesslab-replay', version: 1, task: 'tracking', node: 'sorn',
    provenance: { quadrants_version: 'test-only', backend: 'cpu', dtype: 'float64', seed_partition: 'development', resolved: {} },
    frames: [0, 1].map((tick) => ({ tick, activity: [1, 0], effectors: [0.5], inputs: [1], world: { theta: 0, phi: 1 } })) };
}
describe('recorded display reader', () => {
  test('validates the manifest and a matching development recording', () => {
    expect(parseIndex(index)).toEqual([selected]);
    expect(parseReplay(recording(), selected).frames.length).toBe(2);
  });
  test('rejects traversal and duplicate case identities', () => {
    expect(() => parseIndex({ ...index, cases: [{ ...selected, path: '/replays/../private.json' }] })).toThrow('invalid case');
    expect(() => parseIndex({ ...index, cases: [selected, selected] })).toThrow('duplicate');
  });
  test('requires development provenance and matching model/task', () => {
    const replay = recording();
    replay.provenance.seed_partition = 'confirmation';
    expect(() => parseReplay(replay, selected)).toThrow('provenance');
    expect(() => parseReplay({ ...recording(), node: 'falandays' }, selected)).toThrow('provenance');
  });
  test('rejects empty, backwards, changing-width and nonfinite frames', () => {
    expect(() => parseReplay({ ...recording(), frames: [] }, selected)).toThrow('no frames');
    const backwards = recording(); backwards.frames[1].tick = 0;
    expect(() => parseReplay(backwards, selected)).toThrow('frame');
    const changed = recording(); changed.frames[1].activity.push(1);
    expect(() => parseReplay(changed, selected)).toThrow('dimensions');
    const bad = recording(); bad.frames[0].effectors[0] = NaN;
    expect(() => parseReplay(bad, selected)).toThrow('frame');
    const analogue = recording(); analogue.frames[0].activity[0] = 0.2;
    expect(() => parseReplay(analogue, selected)).toThrow('frame');
  });
  test('stops at the final frame without fabricating subsequent states', () => {
    expect(nextFrame(0, 2)).toBe(1);
    expect(nextFrame(1, 2)).toBe(1);
    expect(nextFrame(0, 0)).toBe(0);
  });
});
