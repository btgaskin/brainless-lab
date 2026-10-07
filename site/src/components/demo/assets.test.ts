import { describe, expect, test } from 'bun:test';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { parseIndex, parseReplay } from './replay';

describe('generated Quadrants display assets', () => {
  test('all published cases pass the same reader used by the player', () => {
    const directory = resolve(import.meta.dir, '../../../public/replays');
    const document = JSON.parse(readFileSync(resolve(directory, 'index.json'), 'utf8'));
    const cases = parseIndex(document);
    expect(cases.length).toBe(8);
    for (const selected of cases) {
      const bytes = readFileSync(resolve(directory, selected.path.split('/').pop()!));
      const replay = parseReplay(JSON.parse(bytes.toString('utf8')), selected);
      expect(replay.frames.length).toBeGreaterThan(0);
      const entry = document.cases.find((item: { id: string }) => item.id === selected.id);
      expect(createHash('sha256').update(bytes).digest('hex')).toBe(entry.sha256);
    }
  });
});
