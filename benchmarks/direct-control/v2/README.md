# Four-task direct-control benchmark, version 2

Version 2 adds binary delayed-cue recall to the frozen Tracking, Pong, and Plank CartPole
Easy harnesses. It keeps the two 200-node profiles from v1: `falandays_direct_v1` and
`sorn_direct_v1`. Their mechanisms, random assembly policies, and online plasticity are
unchanged. Only external input gain is selected per task. No output layer is trained.

The protocol is frozen. Confirmation is pending for all four tasks. The existing v1
definition and artifacts remain unchanged; v1 observations are not relabelled as v2 data.

The committed recall development tables were reproduced from clean source commit
`7fa45446`. Every gain-sweep and pilot outcome, response diagnostic, and statistic matched
the initial run. The replay updates the portable initial-state representation and resource
columns; it supplies no additional independent observations.

## Delayed-cue contract and admission

Each independent block constructs one randomised world and one fresh reservoir. A fair
binary cue appears for eight neural frames. A blank delay is drawn uniformly from 8, 32,
and 128 frames, followed by eight response frames. One world step is one neural frame.
The episode ends after its response, with a maximum horizon of 144 and no warm-up.

Three receptors expose left cue, right cue, and go. Two effectors express left and right
evidence. Only response-period evidence is accumulated. An exact tie chooses left and is
recorded. Pre-response actions cannot store the answer in the environment.

The outcome key is `recall_accuracy`. A completed trial has raw value 0 or 1, and the
normalised value is identical under analytic anchors 0 and 1. An incomplete episode is
missing. Chance is 0.5, not the lower anchor. Endpoint values are valid binary observations.

The task passed its phase, action-isolation, deterministic replay, and typed-evaluation
checks. Across 1,024 development seeds, an observation-only memory oracle succeeds on
every trial. A memoryless controller succeeds with persistent cues and remains near chance
with transient or hidden cues. Visibility modes share the same seeded cue and delay.

This is the admission criterion: correct timing, no observation or action leakage, an
effective memory oracle, appropriate memoryless controls, and practical runtime. It does
not require the initial neural profiles to perform above chance.

## Development selections and fresh pilot

Each recall gain receives 64 paired development blocks. The grid is
`0.125, 0.25, 0.5, 1, 2, 4, 8, 16, 32, 64`. Selection maximises mean recall accuracy,
with exact ties resolved by the smaller gain. The selected gains are 0.125 for Falandays
and 1 for SORN. Gains for the first three tasks carry forward from v1.

The fresh 256-block paired recall pilot gives:

| Profile | Correct | Accuracy | Approximate 95% block interval |
| --- | ---: | ---: | --- |
| Falandays | 123/256 | 0.48047 | 0.41915–0.54179 |
| SORN | 126/256 | 0.49219 | 0.43083–0.55355 |

The paired SORN-minus-Falandays difference is 0.01172, with interval −0.07125–0.09468.
These are the standard Student-t block intervals written by `BenchmarkPlan`, not a
claim of exact binomial coverage. Both profiles remain near chance. There is no clear
paired advantage in this pilot, and no claim of equivalence.

`development/` retains gain trials, pilot trials, decisions, ties, task metadata, block
statistics, contrasts, plans, and a source/run manifest. These are development results.
Full standard records remain beneath the locally generated `records/` root.

## Seed partitions

| Stage | Root seeds | Blocks |
| --- | --- | ---: |
| Recall gain selection | 942001 | 64 per gain |
| Fresh recall pilot | 943001 | 256 |
| Tracking v2 confirmation | 951001 | 32 |
| Pong v2 confirmation | 952001 | 32 |
| CartPole v2 confirmation | 953001 | 32 |
| Recall v2 confirmation | 954001 | 512 |

Each profile shares world streams within a paired block and uses its own profile-keyed
topology stream. Reservoir construction and reset occur independently in every block.
The first three tasks retain their v1 horizons, warm-up, and selected gains. Their new
confirmation roots prevent reuse of v1 confirmation observations.

## Reproduce development and inspect confirmation

```bash
julia --project=. examples/delayed_cue.jl
julia --project=. tools/run_delayed_cue_pilot.jl
julia --project=. bin/brainlesslab.jl check-experiment experiments/direct-control/v2
```

The development script writes ordinary sweeps and a paired `BenchmarkPlan`, with complete
records under `records/delayed-cue-development`. It replaces the compact development
tables when rerun; use a clean branch when reviewing a reproduction.

The last command validates the frozen confirmation bundle without running it. Neither
development script executes sealed confirmation. A future confirmation requires the
declared immutable record, block-level analysis, replay, and human acceptance process.

## Shared CTRNN development

`benchmark_evolution_targets(DIRECT_CONTROL_BENCHMARK_V2, node; root_seed, blocks)`
generates this same four-task list for an experimental fixed node design. It holds node
count, neural parameters, integration policy, and input gain constant across tasks.
Each candidate supplies the same genome to every target. See
[`benchmarks/ctrnn-readiness`](../../ctrnn-readiness/README.md) for the bounded development pilots.
