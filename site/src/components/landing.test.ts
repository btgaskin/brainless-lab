import { describe, expect, test } from 'bun:test';

async function source(relativePath: string): Promise<string> {
  return Bun.file(new URL(relativePath, import.meta.url)).text();
}

describe('landing-page structure', () => {
  test('keeps the demonstration inside a dynamic-viewport stage', async () => {
    const hero = await source('./LandingHero.astro');
    const theme = await source('../styles/theme.css');
    const landing = await source('../content/docs/index.mdx');

    expect(hero).toContain('class="bl-landing-stage"');
    expect(hero).toContain('<BrainlessDemo client:load />');
    expect(theme).toContain('min-block-size: calc(100dvh - var(--sl-nav-height))');
    expect(landing).toContain('<div id="more"></div>');
    expect(landing).not.toContain('<FalandaysDemo');
  });

  test('plays recorded cases with development provenance and no numerical engine', async () => {
    const demo = await source('./demo/SimDemo.tsx');
    const canvas = await source('./demo/TaskCanvas.tsx');
    expect(demo).toContain('/replays/index.json');
    expect(demo).toContain('Recording provenance');
    expect(demo).toContain('Recorded frame');
    expect(demo).not.toContain('runDemoWorldStep');
    expect(demo).not.toContain('ControlPanel');
    expect(canvas).toContain('CartPoleRenderer');
    expect(canvas).not.toContain('WallRenderer');
  });
});
