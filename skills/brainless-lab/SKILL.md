---
name: brainless-lab
description: Guide for operating, extending, and interpreting BrainlessLab.jl — the agent-ready Julia lab for behavior from self-organising neural substrates. Covers low/no-code onboarding, simulate/visualize, calibration/profile/sweep/ablation/benchmark/evolution/experiment workflows, evidence states and safeguards, public composition and registries, and design guidance for nodes, bodies, tasks, metrics, and analyses. Use this skill whenever working in the brainless-lab repo or with BrainlessLab.jl, even when the request does not name it. Pair it with the julia skill for language-level correctness, dispatch, inference, allocations, and package hygiene.
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

The user may not know Julia or how to code. Translate their scientific intent into the existing
high-level API, configs, examples, and tools. Do not make them choose source paths, types, or package
commands that the repository can determine. Explain the outcome, expected artifact, and interpretive
limit in plain language; keep implementation detail available but secondary.

## The one idea: neurons as nodes in a collective

Everything is *neurons as nodes within a collective* — the **same node contract at every scale**. There
is one ladder, and one `step!` runs all of it:

```
NodeModel -> Reservoir -> AbstractBody -> Agent -> Ensemble{Environment} -> Task -> Runner -> Run
                                                  \-> Recorder -> (viz/analysis read this, off the hot path)
```

A single-agent task is an `Ensemble` of **one** agent; a dyad is `n_agents=2`; a swarm is `n_agents=N`.
`step!(collective)` runs a solo reservoir and a 200-agent swarm through the *same code path*. When you
catch yourself thinking "the swarm case is different," stop — it almost never is; it's the same abstraction
with `n_agents` turned up. This is the single most important thing to internalise before extending anything.
The task must still declare that it supports a population: `n_agents` is a setup capability, not a magic
keyword that converts an unrelated single-agent task into a swarm environment.

Named, discoverable presets are wired through **registries**. Nodes, tasks, bodies, drives, metrics,
analyses, views, ablations, and optimizers can be registered by symbol and resolved at run time. Julia
generics and directly composed values are equally public: use a registry when discovery or configuration
by name is useful, not as a substitute for types and methods.

## The first run, and the Makie seam

The safest headline workflow does not alter the root environment:

```bash
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=. examples/quickstart.jl
```

The **compute core does not depend on Makie** — `simulate` runs headless. Plotting is a package extension
that activates *only when a Makie backend is loaded*: `CairoMakie` for static figures and GIFs (use this on
SSH/headless), `GLMakie` for interactive `explore(...)` windows. The generic visualization name exists in
the core, but no plotting method is available until a backend activates the extension. Don't add Makie to
the core deps to "fix" it — the weakdep split is deliberate.

## Stable baseline vs experimental platform — the discipline

This distinction is load-bearing and easy to blur; keep it sharp in code, docs, and claims.

- **`:falandays`** (`:falandays_base` is a compatibility alias) is the settled, validated, **authors-faithful** published Falandays
  homeostatic spiking reservoir with its exact constants. It is the reference participants rely on. Validation
  is numerical trajectory parity with the tested local authors-derived reference construction, within the
  declared tolerance, not paper fidelity for every component — say "authors-faithful," not "paper-faithful."
- **Everything else is the experimental platform**: the other Falandays variants (`:falandays_extended`,
  `:falandays_noisy`, `:falandays_ablated`, `:falandays_hemispheric`, `:falandays_oosawa`, `:falandays_dendritic`,
  `:falandays_spatial`, `:falandays_delayed`), the SORN reference node, the compartmental/CTRNN nodes, the
  evolution and embodiment layers, and the collective/ecological extensions. Useful testbed surfaces — but do **not** describe them as the
  published paper model.

When you touch the baseline, assume a fidelity fixture guards it (`test/fixtures/authors_<task>.jld2`); run the
tests. When you add an experimental piece, label it experimental honestly.

The `:shoal_forage` task is a useful example of this division. It places the canonical
`:falandays` node inside an **Experimental** body, world relation, task, protocol, and set of
analyses. The node's parity status does not transfer to the fish-like embodiment or to claims
about social behavior. Its `SectorVision`, `AntagonisticTurnActuator`, `ProximityExposure`,
and `shoal_*` analyses must remain labelled Experimental until their own contracts and
scientific interpretations earn stronger evidence.

For this task, keep **fixed-demand performance** distinct from **operating-point
sensitivity**. `shoal_vision_sweep` compares social-vision conditions at one declared need
regime. `shoal_sensitivity_screen` varies one gain, curve, rate, range, or association rule at
a time. Raw satisfaction is mechanically changed by a depletion-rate intervention; use the
reported no-contact floor and `material_regulation_gain` when comparing demand levels, while
still noting that the intervention also changes feedback reaching the reservoir. Neither
screen estimates parameter interactions or licenses calling the best observed cell optimal.

Fixture parity validates the tested node update, not every task, body, ecological mechanism, biological
interpretation, or study. Read `site/src/content/docs/platform-limits.mdx` before broadening a claim.

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

Read the matching reference before building:

- **A new node / reservoir** → `references/designing-nodes.md`. The key design question is *where adaptation
  lives*: in online-plastic weights (Falandays — fair to test untrained) or in fixed-weight dynamics
  (compartmental/CTRNN — meaningless untrained, **must be evolved**). Get this wrong and every comparison is
  unfair. Prefer a kwarg/preset bundle over a whole new `<: Reservoir` when the change is parametric.
- **A new environment / task / body** → `references/designing-environments-and-tasks.md`. The central object is
  the synchronous contract (`sample!` → sensor → encoder → reservoir → actuator → dynamics/world → effects →
  physiology). Prefer one composed `Embodiment` over organism-specific body subclasses. Effector semantics are
  *intentionally non-uniform* across tasks, which is exactly why raw scores are **not comparable across tasks** —
  design scoring against a meaningful floor/ceiling.
- **A new analysis / measure** → `references/designing-analyses.md`. Read this even just to *interpret* results.

The Core [extension guide](https://brainless-lab.pages.dev/core/extend/) maps the remaining public families: drive, intervention, physical component,
physiology, optimizer/development, metric, and view. Prefer a parameter preset or composed value to a new
type when the contract has not changed.

## Evidence states are part of the API

Use the ladder in `references/research-workflow.md`: conformance → calibration → exploration →
tuning/training → variance pilot → frozen protocol → sealed confirmation → robustness → promoted
evidence. Never call the best observed sweep cell an optimum, use tuned seeds as confirmation, or treat
a committed run-dir as automatically promoted.

The independent randomized block or run is normally the inferential unit. Agents and ticks nested in one
world do not multiply sample size. The null follows the claim: random action, blind/off, matched sham or
shift, mechanism ablation, model baseline, and oracle/reference answer different questions. Exact replay is
a regression control, not a causal null.

Software readiness is orthogonal to study evidence. The
[Core handbook](https://brainless-lab.pages.dev/core/getting-started/) documents stable
composition contracts; the
[Experimental catalog](https://brainless-lab.pages.dev/experimental/) lists capabilities
with repository-backed source, example, and test metadata. `available` and `integrated`
describe software readiness, not construct validity or evidence promotion.

Use `task_outcome(sim)` as the canonical task result handoff. It returns
`(key, raw, normalized)` for the objective declared by the task and `nothing` when the task
declares no scalar objective. Legacy metric fields remain diagnostics and may be useful, but
they do not define the cross-task outcome contract.

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
Entity-aligned channels carry stable `EntityID`s in `EntityFrame`; nulls, analyses, and views must align by
those IDs rather than assuming vector position is identity. Unknown non-entity channels are not safe to pass
through a surrogate silently.

## Reference files

Read the relevant file in full when the task calls for depth — don't reconstruct API or schema details from
memory.

- **`references/usage-and-workflows.md`** — the high-level API (`simulate` kwargs, `SimResult`, `visualize` /
  `animate` / `explore` / `replay`, the recorder), discovery functions, and end-to-end recipes (baseline run,
  swarm/dyad, headless output). Start here to *use* the lab.
- **`references/cli-tools.md`** — the batch/tooling surfaces: `bench/` (cross-node comparison,
  `train.jl`, `compare.jl`), `profile/` (single-node deep stats), `sweep/` (parameter + ablation
  sweeps), and `calibration/`. Their separate project environments, exact commands, run-dir outputs,
  and the **sweep TOML config schema**. Composed protocols live in `experiments/`.
- **`references/designing-nodes.md`** — the node contract as a design contract; the three families and how each
  must be tested (untrained vs evolved); composition-over-new-types; the `pack_params`/`snapshot_state` (genome
  vs runtime state) split and `genome_type`; registration and type-stability pitfalls.
- **`references/designing-environments-and-tasks.md`** — `AbstractBody`/`Embodiment`, stable component ports,
  direct task adapters versus `ObjectWorld` and the established situated adapter, non-uniform effectors,
  `TaskSpec` scoring, one-to-many ensembles, multiple needs, and component/task registration.
- **`references/designing-analyses.md`** — the analysis contract, the criticality / collective / information
  measure families and their caveats, and above all the **null-test discipline** (circular-shift null, MR
  estimator, windowed vs pooled) plus a checklist for adding a validated measure.
- **`references/research-workflow.md`** — evidence states, experimental units, controls, tuning/confirmation
  separation, prospective power, and promotion provenance. Read before designing or interpreting a study.
- **`references/agentic-safeguards.md`** — how to translate no/low-code requests, isolate work, protect sealed
  evidence and user data, verify changes, and hand off without overstating what was established.

## Naming and conventions

Keep **"Reservoir"** for the node collective (the nodes are untrained by default) — not "Network"; this naming
was chosen deliberately, don't re-propose the rename. User-facing documentation lives in the Astro/Starlight
site under `site/` (published at <https://brainless-lab.pages.dev>); canonical contracts live
under `/core/`, experimental capabilities under `/experimental/`, and the old `docs/*.md` set is retired.

Use the current public body vocabulary exactly: `AbstractBody` is the dispatch boundary and `Embodiment` is the
generic concrete composition. Its stable-ID components are geometry, sensors, encoders, actuators, dynamics,
physiology, traits, and state. `ObjectWorld` is the generic fixed-population physical world; the older
`SituatedEnvironment` remains an adapter for the established torus, forage, and signalling behavior.
Do not introduce organism-specific body classes when component values express the difference.

For discoverable physical parts, query `components()` / `component_info(...)`; readiness is software-scoped:
`:available` is discoverable/materializable, `:integrated` adds standard runtime + exact serialization + docs +
an executable example, and `:core` is stable/default with named core-test coverage. Scientific
evidence status remains a separate study property.
The minimal differential-robot kit has `:core` software readiness: disc geometry, explicit
no-physiology, spectral camera, identity encoder, differential-drive actuation, and
differential-drive dynamics. Other built-in physical components remain `:integrated`.
`ObjectWorld` is still an Experimental composition feature. Embodiment TOML materializes through
`read_embodiment_config` → `materialize_blueprint` or `materialize_embodiment`. `DevelopmentSpec` evolves bounded
real scalar paths on stable component IDs into a fresh runnable phenotype. Paths may use one-based tuple indices
or stable named collection members such as `variables.energy.gain`; it does not vary structure, schedule
births, or encode runtime state.

For the bounded moving-shoal demonstrator, run
`julia -t 4 --project=. experiments/run.jl shoal_vision_sweep`. The default is an explicitly
underpowered two-block pilot that retains all sight/control conditions. Interpret material-
need satisfaction as the primary endpoint. Keep physical cohesion (nearest-neighbour distance
and largest proximity component), displacement coherence, and the perceptual graph as separate
descriptive outcomes; do not convert them into a generic intelligence or shoaling score. With
`record_every > 1`, contact counts and chord-based movement are recorder-grid diagnostics.
Always inspect wall occupancy: common boundary following can raise displacement coherence
without producing a cohesive shoal.
