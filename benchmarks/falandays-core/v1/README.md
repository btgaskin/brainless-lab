# Falandays core benchmark, version 1

This exploratory benchmark describes the canonical Falandays node on the two core tasks.
It does not compare Falandays with another node.

The protocol runs 20 independent blocks for Tracking and 20 for Pong. Each block contains
one trial and constructs a fresh reservoir. Tracking scores the final 200 ticks of a
1,000-tick run. Pong scores the final 1,000 ticks of a 2,000-tick run.

The record reports each task's raw and normalised score with a 95% Student-t interval.
Each normalised score uses the anchors declared by that task. The two normalised scores
remain different quantities and are not combined.

Validate the protocol with:

```bash
julia --project=. bin/brainlesslab.jl check \
  benchmarks/falandays-core/v1/benchmark.toml
```

The committed `record/` directory was generated from a clean repository state with Julia
1.10.11. `record.toml` contains the exact Git revision, Julia version, generated artifact
inventory, and SHA-256 checksums.
