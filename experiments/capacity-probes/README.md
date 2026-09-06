# Capacity-probe development proposals

Stage 1 implements the library, controls and decoding diagnostics. The `v1/` bundles are
planned Stage 2 studies, not executed model comparisons. Read the public
[capacity-probe guide](https://brainless-lab.pages.dev/benchmarks/probes/).

Validate without simulation from the repository root:

```bash
julia --project=. bin/brainlesslab.jl check-experiment experiments/capacity-probes/v1/native_pilot
```

The three bundles use ordinary operations: `calibration` contains 28 input-gain sweeps;
`native_pilot` contains one paired seven-cell benchmark plan; `decoding` contains 24
block-scoped profiles. They reuse Falandays, SORN and the exact saved CTRNN nominees at
200 nodes, with each profile's parameters or genome fixed across tasks.

Measure runtime first. Calibrate on development seeds, apply selected gains in a new
pilot protocol, then estimate variance. Gain 1 and sample sizes are proposals. Native and
decoder scores have separate meanings. Connections, internal states and integration work
differ between models. No cross-task aggregate is defined.

Generate fresh bundles with `tools/capacity_probes/plan_study.jl`. Its
`capacity_study_bundles(cells=capacity_probe_presets())` form covers all 64 cells.
The default selects one starting cell per family. The generator writes plans only.
Confirmation, robustness and admission require later decisions and a frozen protocol.
Existing benchmark versions and accepted records are not modified by this study.
