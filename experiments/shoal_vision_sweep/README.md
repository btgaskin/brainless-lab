# Shoal vision sweep

This is an **Experimental** moving two-resource demonstrator, not a calibrated
benchmark. It asks whether the distance over which independent canonical
Falandays nodes can see conspecifics changes material-need satisfaction, and
whether any change depends on an active association need or on correctly
aligned social bearings.

The checked-in protocol retains the intended four-block design. The default CLI
run is explicitly an underpowered pilot: it keeps all 22 conditions per block,
but uses two blocks and 1,500 ticks (500 warm-up). Its purpose is to see the
shape and scale of the condition differences and validate the pipeline. It does
not support p-values, criticality claims, or confirmatory language.

```bash
julia -t 4 --project=. experiments/run.jl shoal_vision_sweep
```

Use `profile=full` only when the full four-block, 4,000-tick protocol is wanted.
Every run writes its resolved profile, job list, seed ledger, hashes, completion
status, per-run and per-agent tables, paired contrasts, and figure input under
the git-ignored `experiments/runs/shoal_vision_sweep/` directory. Completed jobs
are atomic and resume-safe within that directory.

Resource-contact and movement diagnostics are reconstructed on the recorder
grid. With the default `record_every = 5`, contact rates are sampled lower
bounds and path lengths are chord-based lower bounds. The primary need-
satisfaction endpoint is evaluated directly from the recorded need state.
