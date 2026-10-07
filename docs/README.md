# BrainlessLab documentation

The maintained guide lives under `site/src/content/docs/`. Start with the task you
want to perform:

| Task | Guide |
| --- | --- |
| Run and inspect a simulation | [First simulation](../site/src/content/docs/tutorials/first-simulation.mdx) |
| Compare conditions | [Comparison guide](../site/src/content/docs/tutorials/compare-conditions.mdx) |
| Understand the design | [System map](../site/src/content/docs/handbook/system-map.mdx) |
| Measure speed and memory | [Performance guide](../site/src/content/docs/python/performance.mdx) |
| Change or extend the code | [Contributing](../CONTRIBUTING.md) |
| Check supported capabilities | [Platform limits](../site/src/content/docs/platform-limits.mdx) |

`docs/python/` contains the architecture, implementation exercises, qualification
receipts and upstream issue draft. The small [BrainlessLab skill](../skills/brainless-lab/SKILL.md)
routes agents to these same maintained sources.

Preview or check the site:

```bash
cd site
bun install --frozen-lockfile
bun run dev
```

```bash
bun test
bun run typecheck
bun run build
```

Follow [WRITING.md](WRITING.md). Commands and claims must match source, tests and
records. Historical scientific artefacts retain their original source revisions;
[ARCHIVE.md](../ARCHIVE.md) provides the boundary without maintaining another runtime guide.
