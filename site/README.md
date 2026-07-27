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

## Deploy

The `Deploy site` GitHub Actions workflow builds `site/dist` and uploads it to the
`brainless-lab` Cloudflare Pages project after each push to `main`. A maintainer must:

1. Create a Cloudflare account API token with `Account` → `Cloudflare Pages` → `Edit`.
2. Add the account ID as the GitHub Actions repository secret `CLOUDFLARE_ACCOUNT_ID`.
3. Add the API token as the GitHub Actions repository secret `CLOUDFLARE_API_TOKEN`.
4. Confirm that the Pages project is named `brainless-lab` and its production branch is `main`.
5. Disable Cloudflare's automatic branch deployments if the existing Git integration would
   otherwise deploy the same commit a second time.

Run the workflow manually once after adding the secrets. The workflow's `production`
environment records the URL returned by Cloudflare.

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
