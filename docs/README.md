# BrainlessLab documentation

The public guide lives under [`site/`](../site/) and is published at
<https://brainless-lab.pages.dev>. It is the human-readable account of the current public
interfaces.

The main entry points are:

- [Run your first simulation](https://brainless-lab.pages.dev/tutorials/first-simulation/)
- [System map](https://brainless-lab.pages.dev/handbook/system-map/)
- [Research records](https://brainless-lab.pages.dev/research/)
- [Extend BrainlessLab](https://brainless-lab.pages.dev/handbook/extending/)
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
