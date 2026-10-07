import { describe, expect, test } from 'bun:test';

async function source(relativePath: string): Promise<string> {
  return Bun.file(new URL(relativePath, import.meta.url)).text();
}

describe('landing-page structure', () => {
  test('introduces the platform beside the visual and places task illustrations in the guide', async () => {
    const hero = await source('./LandingHero.astro');
    const landing = await source('../content/docs/index.mdx');
    const guide = await source('../content/docs/start.mdx');

    expect(hero).toContain('data-page-title>BrainlessLab</h1>');
    expect(hero).toContain('<NeuronRecording />');
    expect(hero).not.toContain('TaskPreview');
    expect(guide).toContain('<TaskPreview />');
    expect(landing).not.toContain('TaskPreview');
    expect(landing).toContain('What’s it like to be a neuron?');
    expect(landing).toContain('not a BrainlessLab simulation');
    expect(landing).toContain('does not establish cognition');
    expect(landing).not.toContain('bl-qr-card');
  });

  test('retains the guide header and essential routes', async () => {
    const header = await source('./Header.astro');
    const hero = await source('./LandingHero.astro');
    const landing = await source('../content/docs/index.mdx');
    expect(header).toContain('@astrojs/starlight/components/Header.astro');
    expect(header).toContain('<DefaultHeader />');
    expect(header).toContain('aria-label="Primary navigation"');
    for (const route of ['/tutorials/first-simulation/', '/handbook/system-map/']) {
      expect(hero).toContain(route);
    }
    for (const route of ['/tutorials/reproducible-profile/', '/tutorials/compare-conditions/', '/platform-limits/', '/research/catalogue/']) {
      expect(landing).toContain(route);
    }
  });

  test('shows task previews with documentation links and no model results or recorded-run controls', async () => {
    const preview = await source('./TaskPreview.astro');
    const controller = await source('./task-preview-controller.ts');
    for (const task of ['tracking', 'pong', 'cartpole-plank-easy', 'delayed-cue']) {
      expect(preview).toContain(`/benchmarks/tasks/${task}/`);
    }
    expect(preview).toContain('View docs');
    expect(preview).not.toContain('Falandays');
    expect(preview).not.toContain('SORN');
    expect(controller).not.toContain('fetch(');
    expect(controller).not.toContain('setInterval(');
  });
});
