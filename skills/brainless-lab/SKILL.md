---
name: brainless-lab
description: Guide for running, extending, and interpreting BrainlessLab.jl — the Julia lab for "brainless" cognition (behaviour from collectives of simple neuron-like nodes). Covers the high-level API (simulate/visualize/explore), the registry model, the four CLI tools (bench/profile/sweep/calibration), and design guidance for adding nodes, environments/tasks, and analyses. Use this skill whenever working in the brainless-lab repo or with BrainlessLab.jl — running a simulation, benchmarking or sweeping, interpreting outputs, or designing a new node/reservoir, task/environment, body, metric, or analysis measure — even when the request doesn't name the skill. Pair it with the `julia` skill for the language-level concerns (type stability, allocations, dispatch).
---

# BrainlessLab.jl — running, extending, and interpreting the lab

BrainlessLab is a summer-institute testbed (DISI 2026) for **"brainless" cognition**: behaviour that
emerges from collectives of simple neuron-like nodes with no homunculus and no hand-wired control. It
is a *framework for other people to run experiments* around a settled baseline — not a vehicle for one
person's model. That framing decides almost every design call: prefer a clean seam others can extend
over a clever one-off, and never quietly break the baseline.

This skill is a way of thinking about the lab, not a command cheatsheet. Hold the few load-bearing ideas
below and the rest — which script, which kwarg, which measure — follows from them or from a `references/`
file. For anything about the *Julia itself* (why a `step!` allocates, is a node struct type-stable, how to
profile a sweep), use the **`julia` skill** alongside this one; this skill assumes that layer is handled.

## The one idea: neurons as nodes in a collective

Everything is *neurons as nodes within a collective* — the **same node contract at every scale**. There
is one ladder, and one `step!` runs all of it:

```
NodeModel -> Reservoir -> Body -> Agent -> Ensemble{Environment} -> Task -> Runner -> Run
                                                  \-> Recorder -> (viz/analysis read this, off the hot path)
```

A single-agent task is an `Ensemble` of **one** agent; a dyad is `n_agents=2`; a swarm is `n_agents=N`.
`step!(collective)` runs a solo reservoir and a 200-agent swarm through the *same code path*. When you
catch yourself thinking "the swarm case is different," stop — it almost never is; it's the same abstraction
with `n_agents` turned up. This is the single most important thing to internalise before extending anything.

Every part is wired through a **registry**. Nodes, tasks, bodies, drives, metrics, analyses, views,
ablations, and optimizers are each registered by symbol and resolved at run time. That is why you can swap
a node family or add your own part *without forking the framework* — you `register_*!` a new one and it
composes. The registries are the extension surface; treat them as the public API.

## The two-liner, and the Makie seam

The headline workflow is two lines:

```julia
using BrainlessLab, CairoMakie
sim = simulate(:wall; node=:falandays_base, ticks=300)   # authors-faithful baseline, 1 agent
visualize(sim)                                            # spike raster + rate + trajectory
```

The **compute core does not depend on Makie** — `simulate` runs headless. Plotting is a package extension
that activates *only when a Makie backend is loaded*: `CairoMakie` for static figures and GIFs (use this on
SSH/headless), `GLMakie` for interactive `explore(...)` windows. If `visualize` is undefined, you forgot to
load a backend. Don't add Makie to the core deps to "fix" it — the weakdep split is deliberate.

## Stable baseline vs experimental platform — the discipline

This distinction is load-bearing and easy to blur; keep it sharp in code, docs, and claims.

- **`:falandays_base`** (alias `:falandays`) is the settled, validated, **authors-faithful** 2021 Falandays
  homeostatic spiking reservoir with its exact constants. It is the reference participants rely on. Validation
  is *bit-fidelity to the authors' construction*, not paper-fidelity for every component — say "authors-faithful,"
  not "paper-faithful."
- **Everything else is the experimental platform**: the other Falandays variants (`:falandays_extended`,
  `:falandays_noisy`, `:falandays_ablated`, `:falandays_hemispheric`, `:falandays_oosawa`, `:falandays_dendritic`,
  `:falandays_spatial`, `:falandays_delayed`), the SORN reference node, the compartmental/CTRNN nodes, the
  evolution layer, and the swarm/VEN extensions. Useful testbed surfaces — but do **not** describe them as the
  2021 paper model.

When you touch the baseline, assume a fidelity fixture guards it (`test/fixtures/authors_<task>.jld2`); run the
tests. When you add an experimental piece, label it experimental honestly.

## Discovery-first: ask the registries, don't hardcode

The registries are the live source of truth. Before assuming what exists, call them:

```julia
variants()            # registered node symbols
tasks()               # registered task symbols
analyses(); task_analyses(:forage)   # registered measures (some labeled "experimental")
```

Any symbol list you hardcode in docs or code will drift; a `variants()` call will not. This is also how you
sanity-check that your `register_*!` actually landed.

## Designing something new — the posture

Adding a part means **adding methods to the package generics** — you `import BrainlessLab: step!, effectors,
...` and define methods; `using` will *not* let you extend them. This is the most common first mistake. Start
from `examples/templates/new_project/`, get a single `simulate(:wall; node=:mynode)` to run, and only then
reach for `bench`/`sweep`.

Three design surfaces, three references — read the matching one before building:

- **A new node / reservoir** → `references/designing-nodes.md`. The key design question is *where adaptation
  lives*: in online-plastic weights (Falandays — fair to test untrained) or in fixed-weight dynamics
  (compartmental/CTRNN — meaningless untrained, **must be evolved**). Get this wrong and every comparison is
  unfair. Prefer a kwarg/preset bundle over a whole new `<: Reservoir` when the change is parametric.
- **A new environment / task / body** → `references/designing-environments-and-tasks.md`. The central object is
  the sensorimotor contract (receptors `R` → reservoir → effectors `E` → decode → actuate). Effector semantics
  are *intentionally non-uniform* across tasks, which is exactly why raw scores are **not comparable across
  tasks** — design scoring against a meaningful floor/ceiling.
- **A new analysis / measure** → `references/designing-analyses.md`. Read this even just to *interpret* results.

## Rigor: null-test every measure

The analysis layer is deliberately **measure-agnostic**: analyses are pure functions over the recorder's
channels, so you can point any candidate measure at a `SimResult`. That freedom is also the trap — a number
that looks "critical" at the collective scale is often an artifact of shared input. The library gives you the
check: a per-agent **circular-shift null** (`crossshift_null`) that preserves each agent's own temporal
statistics while destroying cross-agent alignment. Clear it before trusting any cross-agent measure, prefer
the subsampling-robust estimators the library ships (MR branching over the naive slope), and use the
`_windowed` variants when the process is non-stationary. Treat an un-null-tested cross-agent number as
shared-drive until shown otherwise — this project's own swarm runs are a standing reminder that measures which
*look* collective often don't survive the null. See `references/designing-analyses.md`.

## Reference files

Read the relevant file in full when the task calls for depth — don't reconstruct API or schema details from
memory.

- **`references/usage-and-workflows.md`** — the high-level API (`simulate` kwargs, `SimResult`, `visualize` /
  `animate` / `explore` / `replay`, the recorder), discovery functions, and end-to-end recipes (baseline run,
  swarm/dyad, headless output). Start here to *use* the lab.
- **`references/cli-tools.md`** — the four CLI tools: `bench/` (cross-node comparison, `train.jl`, `compare.jl`),
  `profile/` (single-node deep stats), `sweep/` (parameter + ablation sweeps), `calibration/`. Their separate
  project environments, exact commands, run-dir outputs, and the **sweep TOML config schema**.
- **`references/designing-nodes.md`** — the node contract as a design contract; the three families and how each
  must be tested (untrained vs evolved); composition-over-new-types; the `pack_params`/`snapshot_state` (genome
  vs runtime state) split and `genome_type`; registration and type-stability pitfalls.
- **`references/designing-environments-and-tasks.md`** — the sensorimotor contract, the `PassthroughBody` /
  `VENBody` seam, non-uniform effector semantics, `TaskSpec` and scoring (floor/ceiling `normalized_score`),
  single-agent↔swarm as one abstraction, coupling = vision, and the `register_task!`/`register_body!` family.
- **`references/designing-analyses.md`** — the analysis contract, the criticality / collective / information
  measure families and their caveats, and above all the **null-test discipline** (circular-shift null, MR
  estimator, windowed vs pooled) plus a checklist for adding a validated measure.

## Naming and conventions

Keep **"Reservoir"** for the node collective (the nodes are untrained by default) — not "Network"; this naming
was chosen deliberately, don't re-propose the rename. User-facing documentation lives in the Astro/Starlight
site under `site/` (published at <https://brainless-lab.pages.dev>); the old `docs/*.md` set is retired.
