# Oosawa drive, the dendritic port, and the Neurons docs — working guide

Status: brief for implementation (2026-07-04). Covers four bundled pieces of work that
came out of a review of the Oosawa-drive variant of the Falandays node:

1. Document the *causes* (the biological + numerical "why") inside the Oosawa drive code.
2. Reconcile the divergent `:falandays_oosawa` defaults so the variant behaves the same
   however it is constructed.
3. Port the one Falandays-family variant that was missed in the Julia rewrite — the
   **dendritic eligibility-tag plasticity** node (`v0.2/crho/node_dendritic.py`).
4. Docs: a summary of the Oosawa (2007) paper + biological inspiration, and a new
   **Neurons** page covering neuron features (spiking dendrites, etc.) with citations.

The guiding bar throughout: *minimal, biologically motivated, and internally consistent*.
Match the existing Julia idiom — the drive/plasticity as a **trait dispatched by type**,
not a runtime branch inside `step!`.

---

## 1. Document the causes in the Oosawa drive

`src/nodes/Drives.jl` — `OosawaDrive` and `apply_drive!(::OosawaDrive, …)` currently carry
zero comments. The Python reference (`v0.2/crho/falandays.py`, lines ~140–148 and ~221–229)
had the rationale and it was dropped in the port. Restore it, grounded in the paper.

The two facts that must be captured in comments:

- **Why the noise is added to `acts` *before* rectify/threshold, not after.** The leak
  (`acts ← acts·(1−λ) + …`) integrates the injected Gaussian current into a
  temporally-correlated **Ornstein–Uhlenbeck** subthreshold fluctuation that occasionally
  crosses threshold → spontaneous, input-independent spiking. This is exactly Oosawa's
  Eq. (1): `C·dδV/dt = −G·δV + I(…)`, a Langevin/OU equation for the *basic* membrane
  potential fluctuation; the leak is the `−G·δV` relaxation and the noise is the random
  force. Adding noise post-threshold would be white jitter on the output, not an OU
  membrane process.
- **Why the deficit references the firing threshold `μ·T` (= 2T), not the target `T`.**
  If the gain keyed off `T − acts`, the drive would equilibrate the membrane *at* the
  set-point and essentially never push it past `μ·T` → no spontaneous spikes. Keying off
  `max(0, μT − acts)` means the drive stays on until the node can actually fire, then
  switches off. This is the target-modulated gate: σ ramps up when a node is starved and
  vanishes at set-point (cf. the paper's regulation of spontaneous-spike *frequency* by
  internal state, §5–6).

Keep it to a tight comment block — a few lines above the struct and above the loop body,
not an essay. Reference `docs .../nodes/falandays.mdx §"The Oosawa drive"` and the paper.

---

## 2. Reconcile the `:falandays_oosawa` defaults

There are two constructors and they disagree:

- `falandays_oosawa(args…; membrane_noise=0.0, noise_gain=0.0, …)` — `src/nodes/Falandays.jl:572`.
  Both zero ⇒ σ ≡ 0 ⇒ an **inert** drive (a NoDrive that still draws noise).
- `_falandays_oosawa_native(…; membrane_noise=0.0, noise_gain=0.8, …)` — `src/api/Highlevel.jl:254`.
  The registered node preset. `noise_gain=0.8` ⇒ an **active** drive.

So `build(:falandays_oosawa)` and `falandays_oosawa()` produce opposite behaviour under one
name. Fix: make the convenience constructor default to the same active preset
(`noise_gain=0.8`, `membrane_noise=0.0`) so the variant means one thing. Grep for callers
of `falandays_oosawa(` first (tests, demos, `demo/`, notebooks) and confirm none rely on the
inert default; update any that do. The `σ = 0.8·max(0, 2T − acts)` form is already the one
documented in `README.md`, `docs/nodes.md`, and `docs/index.html`, so aligning the code to
`0.8` also makes code and docs consistent.

Sanity: `OosawaDrive()` with both fields `0.0` is itself an inert default. Consider whether
the registry default for `:oosawa` should carry `noise_gain=0.8` too, so a bare
`drive=:oosawa` is active. Use judgment; document whatever you choose in a one-line comment.

---

## 3. Port the dendritic eligibility-tag variant to Julia

**Source of truth:** `v0.2/crho/node_dendritic.py` (`DendriticReservoir`). This is the one
Falandays-family member with no Julia equivalent. Do **not** conflate it with the
`compartmental_*` nodes (`src/nodes/Compartmental*.jl`) — those are a separate biophysical
multi-compartment ODE model. This variant is the *homeostatic Falandays neuron* with
**per-dendrite eligibility-gated plasticity** and a **logistic** (saturating) drive.

### What it adds over base Falandays

1. **Dendritic compartments.** Recurrent edges are assigned to one of `n_dendrites` (default
   4) compartments via `dend_id[i,j]` (drawn once from a *separate* RNG, `seed+777`). Each
   dendrite has its own leaky activation `dend_acts[N, n_dendrites]` that integrates only the
   presynaptic current routed to it: `dend_acts ← dend_acts·(1−λ) + dend_input`.
2. **Logistic drive** (`logistic_drive(deficit, floor, smax, d0, w)`): a saturating
   sigmoid `floor + (smax−floor)/(1+exp(−(deficit−d0)/w))`, applied to the one-sided node
   deficit. Distinct from Oosawa's *linear* `noise_gain·max(0, …)`. Applied to dendrites
   (`dend_drive`) and/or soma (`soma_drive`).
3. **Dendritic spikes → eligibility tags.** A dendrite that crosses `dend_threshold` (reset
   by subtraction) sets an eligibility tag on all recurrent edges routed to it:
   `tag[i,j] = (dend_id[i,j]==d) & dend_spike[i,d]`.
4. **Eligibility-gated plasticity.** The base rule updates weights from *presynaptically
   active* edges only. Here the gate is widened: `elig = recurrent_mask & ((prev_spikes>0) | tag)`
   — a synapse is plastic if its presynaptic node fired **or** its dendrite branch spiked.
   This is the biologically-motivated departure: local dendritic events license plasticity
   independent of somatic/presynaptic spiking (see the citations in §4 — Urbanczik & Senn
   2014; Payeur et al. 2021).
5. **`eligibility_only` switch.** If `False`, dendritic spikes also inject somatic current
   (`soma_dend_current = dend_spike.sum(axis=1)`); if `True` (default) dendrites influence
   *learning only*, not the somatic membrane.

Read the Python `step()` (lines 117–205) carefully — the ordering matters (dendrite update →
node deficit → dendrite drive+spike → tag → soma current → soma drive → rectify → threshold →
eligibility-gated learn). Reproduce that order.

### How to fit it into the Julia architecture (freedom here — pick the cleanest)

Two viable designs; choose based on how much of `step!` you'd have to duplicate:

- **Preferred if it stays clean — a `Drive` + plasticity trait pair.** The Julia Falandays
  already dispatches the endogenous drive through `apply_drive!(::Drive, …)` and the weight
  update through `learn_connectome!`. The dendritic behaviour is (a) a `LogisticDrive <: Drive`
  and (b) a dendrite-aware connectome/conn-state carrying `dend_id`, `dend_acts`, and the
  eligibility tag, with its own `learn_connectome!` method. This keeps `step!` shared.
  The obstacle: dendrites need per-branch state and a routing pass *inside* the tick, which
  the current `apply_drive!(acts, targets, …)` signature can't see. You may need a small,
  additive hook (e.g. a `predrive_dendrites!`/`route!` step that defaults to a no-op for
  existing drives) rather than forcing everything through `apply_drive!`.
- **Acceptable — a dedicated node** like `Compartmental*.jl`: a `DendriticModel`,
  `DendriticConnectome` (holds `dend_id`), `DendriticConnState` (holds `wmat` + tag),
  `DendriticNodeState` (adds `dend_acts`), a `ReservoirInstance` alias, and its own `step!`.
  More code, but no shoehorning. If the trait route needs more than one intrusive hook into
  the shared `step!`, prefer this.

Whichever you pick, honour the project's non-negotiables (see the `julia` skill): **type
stability** (concrete struct fields; `dend_id::Matrix{Int}`, `dend_acts::Matrix{Float64}`;
parametrise models over the drive type so dispatch stays static), and **no needless
allocation in `step!`** (preallocate the dendrite buffers and the tag matrix; the Python does
`np.zeros((N, n_dendrites))` every tick — don't replicate that, mutate in place). Watch the
`contrib*sel).sum(axis=0)` dendrite-routing inner loop — the naive port allocates an `N×N`
temporary per dendrite per tick; route with an index/accumulation pass instead.

### RNG / reproducibility

- Dendrite assignment uses `default_rng(seed+777)`; recurrent/input/output masks use
  `default_rng(seed)`; noise uses `seed+999983`. Preserve the **same offsets** so a future
  cross-check against the Python reference is possible. Note Julia uses `MersenneTwister`, not
  numpy's PCG64 — so you will **not** get byte-identical streams against v0.2 (the base node
  isn't bit-exact across languages either). Aim for *structural* fidelity (same update, same
  gating, same defaults), not bit-exactness, and say so in a comment.

### Registration + surface

- Register as `:falandays_dendritic` in `src/BrainlessLab.jl` alongside the other
  `register_node!(:falandays_*, …)` lines, with a `_falandays_dendritic_native(...)` in
  `src/api/Highlevel.jl` following the `_falandays_oosawa_native` pattern (defaults:
  `n_dendrites=4, soma_drive=0.0, dend_drive=…, drive_floor=0.0, drive_d0=1.0, drive_w=0.4,
  dend_threshold=1.0, eligibility_only=true`). If it's a `Drive`, also `register_drive!`.
- Export the public names in `src/BrainlessLab.jl`.
- Add tests under `test/` mirroring the existing Falandays-variant tests: construction,
  a determinism/seed test, a "network stays alive" smoke test, and a test that the
  eligibility gate actually widens plastic edges vs base (i.e. a dendritic spike with no
  presynaptic spike still updates a weight).

### Audit while you're here

- `v0.2/crho/node_variant.py` (`SwarmVariantReservoir`, directed Watts–Strogatz + Dale)
  appears already covered by Julia's `:falandays_extended` (`directed_watts_strogatz` in
  `src/nodes/Falandays.jl`, Dale axis). Confirm the mapping and, if anything is genuinely
  missing (e.g. the swarm-collective wiring specifics), note it — don't silently assume parity.
- Confirm no other `v0.2/crho/node_*.py` has been missed (`node_hemispheric.py` is already a
  port *from* Julia, so it's fine).

---

## 4. Docs: Oosawa paper summary + a Neurons page

### 4a. Oosawa paper summary + biological inspiration

Add a section (extend `nodes/falandays.mdx §"The Oosawa drive"`, or a short new page — your
call) summarising:

> **Oosawa, F. (2007). Spontaneous activity of living cells. *BioSystems* 88, 191–201.**
> (See also Oosawa, F. 2001, *Bull. Math. Biol.* 63, 643.)

Points to convey, tied to *why the drive exists in this project*:

- Oosawa distinguishes three stimulus→response regimes in living cells: **reflective**
  (tight, deterministic coupling), **autonomic** (loose coupling — same stimulus, varying
  response), and **spontaneous** (internally generated activity with *no* external stimulus).
  The Oosawa drive is a minimal model of that third regime.
- In *Paramecium*, spontaneous membrane-potential fluctuations (basic OU-like fluctuation +
  spike-like events from field-sensitive channels) trigger spontaneous swimming-direction
  changes. The **basic fluctuation** is Oosawa's Langevin Eq. (1) — this is the OU membrane
  noise our leak integrates; the **spike-like** events (Eq. 2, nonlinear, field-sensitive)
  are the threshold crossings.
- The fluctuation is **metabolically driven** ("active vs quiet cells"): its variance is
  proportional to a *circulating* ionic current sustained by free-energy consumption. Active
  cells (Paramecium, ~3 mV) *produce* large fluctuations; quiet cells (nerve axon, ~0.03 mV)
  *suppress* them. Spontaneity is a built, powered feature, not thermal leakage.
- The **frequency of spontaneous events is regulated by internal state / environment**
  (thermotaxis: fewer direction-changes when heading toward the preferred temperature). This
  is the biological analogue of our **target-modulated gain** — σ up when starved, off at
  set-point — and of *why* spontaneous activity supports exploration/foraging.
- Relevance to the examples: the Oosawa drive is what keeps a **blind or input-starved
  network alive by variance** rather than by deterministic self-excitation, giving the agent
  a source of endogenous exploration — the same role spontaneous direction-changes play in
  Paramecium thermotaxis. Reference the wall/pong/tracking demos.

Keep the math consistent with the existing page ($\sigma_i = \text{noise}_0 + g\max(0, \mu T_i - a_i)$)
and add the OU/Langevin connection.

### 4b. A new "Neurons" page

Create `src/content/docs/nodes/neurons.mdx` (or top-level; your call) and add it to the
sidebar in `site/astro.config.mjs` (under the **Nodes** group, after `falandays`). Purpose:
step back from any single node and cover **features of real neurons and their relevance to
the models here** — what we abstract, what we keep, what a given variant is a caricature of.
Suggested subsections (each: the biology → what BrainlessLab does with it):

- **Membrane integration & leak** → the leaky-integrate step; OU membrane noise (Oosawa).
- **Threshold & reset** → subtractive reset; homeostatic threshold `T` (set-point).
- **Homeostasis / intrinsic plasticity** → the target-update rule; "homeostasis as prediction".
- **Dale's law (E/I)** → the `sign` axis / `:falandays_extended`.
- **Spiking dendrites & dendritic computation** → the new `:falandays_dendritic` variant;
  dendrites as semi-independent nonlinear subunits that gate plasticity locally. **This is
  the subsection that must carry a citation** (see below).
- **Delays & spatial embedding** → `:falandays_delayed`, `:falandays_spatial`.
- **Endogenous / spontaneous activity** → the Oosawa drive.

### 4c. Citations to add

Spiking dendrites / dendritic computation (cite at least one primary review):

- **London, M. & Häusser, M. (2005).** Dendritic computation. *Annual Review of
  Neuroscience* 28, 503–532.
- **Poirazi, P. & Papoutsi, A. (2020).** Illuminating dendritic function with computational
  models. *Nature Reviews Neuroscience* 21, 303–321.
- **Gidon, A. et al. (2020).** Dendritic action potentials and computation in human layer
  2/3 cortical neurons. *Science* 367, 83–87.

Dendrite-gated / local plasticity (for the eligibility-tag mechanism specifically):

- **Urbanczik, R. & Senn, W. (2014).** Learning by the dendritic prediction of somatic
  spiking. *Neuron* 81, 521–528.
- **Payeur, A., Guerguiev, J., Zenke, F., Richards, B. A. & Naud, R. (2021).**
  Burst-dependent synaptic plasticity can coordinate learning in hierarchical circuits.
  *Nature Neuroscience* 24, 1010–1019.

Match the citation style already used in the docs (the falandays page cites the 2021
Falandays paper inline; follow that convention — a References block at the page foot is fine).

---

## Definition of done

- [ ] Oosawa drive carries the OU + threshold-deficit rationale as comments, grounded in the paper.
- [ ] `falandays_oosawa()` and `:falandays_oosawa` agree (active `noise_gain=0.8`); callers updated.
- [ ] `:falandays_dendritic` exists in Julia: node/drive registered, exported, type-stable,
      allocation-lean `step!`, with tests (construction, determinism, alive-smoke, eligibility-gate).
- [ ] `SwarmVariant` vs `:falandays_extended` parity confirmed (or the gap noted).
- [ ] Docs: Oosawa (2007) summary + biological inspiration; new **Neurons** page in the sidebar;
      spiking-dendrite + dendritic-plasticity citations.
- [ ] `julia --project=. -e 'using BrainlessLab'` loads clean; the test suite passes; a quick
      `simulate(:wall; node=:falandays_dendritic, ticks=300)` runs and the network is alive.

Do not commit unless asked — leave the working tree for review.
