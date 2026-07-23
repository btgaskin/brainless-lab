# BrainlessLab site

This directory contains the public BrainlessLab platform guide. It uses
[Astro](https://astro.build) and [Starlight](https://starlight.astro.build), with KaTeX
for equations and React for the small interactive Falandays demonstration.

## Run locally

```bash
cd site
bun install
bun run dev
```

Build and preview the static output:

```bash
bun run build
bun run preview
```

## Content model

The guide is organised by the reader's task:

- start with a diagnostic run and the core task tour;
- run repeatable operations and interpret their records;
- understand the runtime and research architecture;
- extend nodes, bodies, tasks, and analyses;
- inspect experimental capabilities and their readiness.

The public site does not contain historical literature notes or bespoke study pages.
Versioned `ExperimentSpec` bundles live under [`../experiments/`](../experiments/), and
operation records remain the source for generated reports.

Key files:

- `astro.config.mjs` defines navigation and site metadata;
- `src/content/docs/` contains public Markdown and MDX pages;
- `src/content.config.ts` validates content metadata;
- `src/styles/theme.css` defines the visual system;
- `src/components/FalandaysDemo.tsx` contains the browser demonstration;
- `src/simulation/` contains the TypeScript simulation used by that demonstration.

Write equations as `$...$` or `$$...$$`. Follow
[`../docs/WRITING.md`](../docs/WRITING.md) for prose and terminology.
