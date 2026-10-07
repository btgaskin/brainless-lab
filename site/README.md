# BrainlessLab site

This directory contains the public BrainlessLab platform guide. It uses
[Astro](https://astro.build) and [Starlight](https://starlight.astro.build), with KaTeX
for equations and React for recorded output displays. Task illustrations and the
microscopy recording do not run a numerical engine in the browser.

## Run locally

```bash
cd site
bun install --frozen-lockfile
bun run dev
```

Build and preview the static output:

```bash
bun run build
bun run preview
```

## Deploy

The `Python CPU and site` GitHub Actions workflow checks the package and site.
Site deployment is manual. After the exact revision passes CI, use the existing
Wrangler login or run `wrangler login`, then deploy from the repository root:

```bash
cd site && bun run deploy
```

This builds `site/dist` and uploads it to the `brainless-lab` Cloudflare Pages
project on its `main` production branch. Check the returned immutable deployment
URL and `https://brainless-lab.com/` before reporting the site as published.

## Content model

The guide is organised by the reader's task:

- start with a first simulation and the task guide;
- run repeatable operations and interpret their records;
- understand the runtime and research architecture;
- extend models, tasks and analyses;
- inspect supported scope, evidence and history.

Historical pages remain labelled and linked to their original source revisions.
Operation records remain the source for generated reports.

Key files:

- `astro.config.mjs` defines navigation and site metadata;
- `src/content/docs/` contains public Markdown and MDX pages;
- `src/content.config.ts` validates content metadata;
- `src/styles/theme.css` defines the visual system;
- `src/components/NeuronRecording.astro` displays the landing-page still and recording;
- `src/components/TaskPreview.astro` contains scripted task illustrations;
- `src/components/demo/` reads generated development recordings;
- `src/pages/og/` generates social preview images at build time.

Write equations as `$...$` or `$$...$$`. Follow
[`../docs/WRITING.md`](../docs/WRITING.md) for prose and terminology.
