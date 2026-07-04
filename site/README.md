# BrainlessLab site

The documentation **and** outputs site for BrainlessLab.jl — [Astro](https://astro.build) +
[Starlight](https://starlight.astro.build), with equations (KaTeX) and the interactive
Falandays demo as a React island.

## Run it (bun)

```bash
cd site
bun install
bun run dev        # http://localhost:4321
```

Build a static site:

```bash
bun run build      # -> ./dist
bun run preview
```

## Layout

- `astro.config.mjs` — Starlight config: sidebar, KaTeX (remark-math → rehype-katex), React island, brand CSS.
- `src/styles/theme.css` — the warm brand palette (paper / teal / amber / ink), matching the figures in `src/viz/Style.jl`.
- `src/content/docs/*.mdx` — the pages (Introduction, Concepts, Nodes, Environments & Tasks, Analysis, Tooling, Extending, Reference, Outputs).
- `src/components/FalandaysDemo.tsx` — the interactive demo island (currently a scaffold placeholder; wire in `website/src`'s live sim — see the file header).

## Structure

Two halves under one site: **infrastructure docs** (the library) and an **Outputs**
area for publishing experiment results, data, and figures.

Equations use `$…$` / `$$…$$`. A "Source" callout (`<p class="bl-source">`) links a
documented concept to its Julia implementation.

---

A [Diverse Intelligences Summer Institute](https://disi.org) 2026 (Geneva NY) project —
Polyphony Bruna · Benjamin Gaskin · Ian Jackson · William O'Hearn.
