# Falandays and SORN direct-control benchmark, version 1

This frozen benchmark compares two fixed 200-neuron profiles on Tracking, Pong, and
Plank CartPole Easy. Each reservoir acts through the task's existing direct readout. No
linear readout is fitted, and the three task coordinates remain separate.

The benchmark measures untrained, from-scratch direct control. A fresh random assembly
starts each block and may use only its declared online local plasticity. It compares the
complete profiles, including their different fixed input and output pool policies; it does
not isolate the neuronal update rule.

## Fixed model profiles

- `falandays_direct_v1` uses one cross-task Falandays parameter and topology policy.
- `sorn_direct_v1` uses 167 excitatory and 33 inhibitory units, expected E-to-E degree 10,
  dense E-to-I and I-to-E connectivity, three online plasticity rules, and fixed 5% input
  and output fanout.

Both profiles use `N = 200` total dynamic neurons. Their neural parameters, topology
policy, weight distribution, output assembly, and online plasticity remain fixed across
tasks. Random weights and topology are newly drawn from that policy for each independent
block.

The only task-specific selected value is the generic `InterfaceSpec.input_gain`, applied
after the task encoder and before `step!`. The development grid is:

```text
0.125, 0.25, 0.5, 1, 2, 4, 8, 16, 32, 64
```

Each gain receives 16 paired development blocks. Selection uses the task's declared public
profile coordinate: minimum mean absolute heading error for Tracking, maximum mean longest
rally for Pong, and maximum mean balanced steps for CartPole. An exact tie selects the
smaller gain. Selection freezes the model-task cell. The confirmation run then uses 32
untouched paired blocks.

## Frozen development selections

| Task | Profile | Input gain | Development profile mean | Formal outcome mean |
| --- | --- | ---: | ---: | ---: |
| Tracking | Falandays | 1 | 55.7492° | `track_score = 0.4727` |
| Tracking | SORN | 4 | 38.8631° | `track_score = 0.7127` |
| Pong | Falandays | 1 | 4.0000 returns | `hit_rate = 0.4826` |
| Pong | SORN | 32 | 5.1250 returns | `hit_rate = 0.6126` |
| Plank CartPole Easy | Falandays | 8 | 24.2500 steps | `fitness = 24.2500` |
| Plank CartPole Easy | SORN | 8 | 15.1250 steps | `fitness = 15.1250` |

These values are selection data, not confirmation results. The
[`development/selection.toml`](development/selection.toml) manifest pins the clean source
commit, run identifiers, selected values, and hashes for all six 10-cell tables. The CartPole
selections were rerun after its readout was corrected to choose the largest cumulative
output signal over all 24 neural frames. Silent frames do not count as left actions.

## Task timing

| Task | Horizon | Warm-up | Scored interval | Neural frames per world step |
| --- | ---: | ---: | ---: | ---: |
| Tracking | 7,200 | 1,200 | 6,000 | 1 |
| Pong | 7,200 | 1,200 | 6,000 | 1 |
| Plank CartPole Easy | at most 15,000 | 0 | until termination | 24 |

CartPole stops when the episode terminates. Its 32 one-episode blocks are this benchmark's
declared protocol; they do not reproduce the source repository's 1,000-episode evaluation.

## Reproduce development

Validate each file before running it:

```bash
for plan in benchmarks/direct-control/v1/calibration/*.toml; do
  julia --project=. bin/brainlesslab.jl check "$plan"
done
```

Run a selected plan into a development-only records root:

```bash
julia -t auto --project=. bin/brainlesslab.jl run \
  benchmarks/direct-control/v1/calibration/direct_control__tracking__sorn_direct_v1__input_gain.toml \
  --root development-records
```

Use `select_input_gain(result)` on an in-memory `SweepResult`, or apply the same declared
rule to the authoritative cell table. A reproduction checks the six frozen choices; it
does not retune them in version 1.

## Run confirmation

The frozen experiment contains only the confirmation operation. Validate it first:

```bash
julia --project=. bin/brainlesslab.jl check-experiment experiments/direct-control/v1
```

Run it only from a clean source commit that is reachable from `main`:

```bash
julia -t auto --project=. bin/brainlesslab.jl run-experiment \
  experiments/direct-control/v1 --root benchmark-records
```

The run writes one standard benchmark record with 32 paired blocks per task. Submit that
record through the run-only contribution path. A maintainer replay checks execution and a
human maintainer decides whether to accept it. The replay is linked to the submission; it
is not a second independent experiment.

The input gains and confirmation plan are frozen. No confirmation record is accepted yet.
The protocol cannot support a confirmed performance claim until the immutable record,
block-level intervals, paired contrasts, replay, and human review are complete.
