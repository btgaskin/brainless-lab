# BrainlessLab documentation

The public guide lives under [`site/`](../site/) and is published at
<https://brainless-lab.pages.dev>. It is the human-readable account of the current public
interfaces.

The main entry points are:

- [Getting started](https://brainless-lab.pages.dev/core/getting-started/)
- [Operations and records](https://brainless-lab.pages.dev/core/operations-records/)
- [Design a study](https://brainless-lab.pages.dev/core/design-study/)
- [Extend the lab](https://brainless-lab.pages.dev/core/extend/)
- [Platform limits](https://brainless-lab.pages.dev/platform-limits/)

Run the site locally:

```bash
cd site
bun install
bun run dev
```

Use [`WRITING.md`](WRITING.md) when changing repository prose. It defines the maintained
soft-STE profile, British spelling, and preferred platform terms.

Checked-in plans, experiments, examples, tests, and generated records are executable
sources of truth. Documentation must agree with them, but it must not present a planned
protocol or software-ready capability as scientific evidence.
