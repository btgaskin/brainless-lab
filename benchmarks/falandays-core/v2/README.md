# Falandays core benchmark, version 2

This planned anchor-only benchmark describes the canonical Falandays node on Tracking,
Pong, and Wall. It does not compare Falandays with another node, combine task scores, or
yet provide a run record.

The protocol uses 20 independent blocks per task. Each block contains one trial and
constructs a fresh reservoir. Tracking and Pong run for 7,200 ticks and score the final
6,000 ticks after a 1,200-tick warm-up. Wall keeps its 1,000-tick horizon and 200-tick
scored window.

Pong produces about one ball event per 305 ticks. The 6,000-tick scored interval therefore
contains about 20 events, compared with only two or three under the version 1 interval.
Wall is a competence floor-check: the scope-setting measurement was `0.9933` raw and
`0.9703` normalised, close enough to the ceiling that Wall offers little upward
discrimination.

These scope-setting measurements are not a benchmark record or an interval estimate. Run
and review the versioned plan before changing its evidence state from `planned`.

Validate the protocol with:

```bash
julia --project=. bin/brainlesslab.jl check \
  benchmarks/falandays-core/v2/benchmark.toml
```

`cartpole_plank_easy` is a declared frontier task, not a benchmark case. Canonical
Falandays measured `10.0` raw and `0.0007` normalised, so the task remains unsolved by the
canonical node and cannot yet discriminate neural designs above its floor.
