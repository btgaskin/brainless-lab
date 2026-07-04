# A terminal launcher for BrainlessLab.jl — design proposal

Status: **design only, nothing built.** This is a proposal for Bird to rule on before any Julia is
written. Grounded in the actual registries and entry points as of the 2026-07-01 abstraction refactor
(`ReservoirInstance`, morphology seam, per-task `default_morphology`).

## 1. Purpose & audience

The audience is summer-institute participants: people who know they want to "run a reservoir on a task and
see what happens" but don't want to learn `simulate(:wall; node=:falandays_spatial, p0=0.4, lambda=0.2)`
syntax on day one. Per the standing project direction, BrainlessLab is being built as **a framework for
others to run experiments**, not a vehicle for Bird's own research — so the TUI's job is to *lower the
floor*, not to add power a script can't already offer. It should answer "what can I even run?" by making
the registries visibly enumerable and the sensorimotor contract visible before a run starts, not by
teaching Julia.

Relationship to existing entry points — the TUI is a **front-end that composes them**, not a replacement:

| existing surface | stays as | TUI's relationship |
|---|---|---|
| `simulate`/`visualize`/`animate`/`replay` (`api/Highlevel.jl`) | the actual compute/viz calls | TUI calls these directly; it is a caller, nothing more |
| `explore(task; node, kwargs...)` | the interactive GLMakie window | TUI *launches* it (spawns/execs) and hands off; a GLMakie window is its own event loop, not embeddable in a terminal |
| `demo/run.jl` | scripted turnkey GIF+run-dir generator | TUI's "quick run" mode is roughly `demo/run.jl`'s logic exposed as menus instead of flags — could eventually **thin `demo/run.jl` down to a TUI subcommand**, or leave both (see open questions) |
| `bench/` (Benchmark.jl/Pipeline.jl/Stats.jl) | statistical cross-node comparison | out of scope for TUI v0 — a bench sweep runs for a long time unattended and its natural interface is a TOML config + `run.jl`, not an interactive menu. A v1 TUI mode could *launch* a bench config non-interactively (fire-and-forget) but should not try to reimplement bench's config authoring |
| `profile/` (being built now) | per-node structure/IO/branching-ratio/perf HTML | same relationship as bench: TUI can *trigger* a profile build and then open the resulting HTML, but shouldn't own profile's logic |
| `evolve`/`EvolveRunner` | sep-CMA-ES training | in scope as a "launch and walk away" action (long-running, prints progress) — not an interactive tuning surface |

So the TUI's real job is: **make the registries browsable, make one run's parameters legible, and dispatch
to the four things a person actually does** — simulate-and-look-at-a-figure, animate-a-GIF, open-the-live-
GLMakie-window, or replay-a-past-run — plus a "kick off something long-running" escape hatch for evolve/
bench/profile that hands off to their existing CLIs rather than re-implementing them.

## 2. UX / navigation

### 2.1 Flow

```
mode  →  node (or "surprise me" default)  →  task/setup  →  params  →  confirm  →  run
```

Two setups fork at the task step, and the TUI should say so out loud rather than let people discover it by
error:

- **agent–environment** (single-agent): `:wall`, `:tracking`, `:pong`, `:pong_hitrate`, `:cartpole*` —
  `PassthroughBody`, one agent, a `TaskSpec` with known `default_ticks`/`default_window`/score
  floor-ceiling.
- **multi-agent / collective**: `:torus` — `VENBody`, `n_agents`, a `SwarmConfig`/`TorusMedium`, no
  `TaskSpec` (see `contracts.md`: torus isn't a `TaskSpec` with a normalized score; it's read through
  collective metrics — polarization/milling/liveness).

### 2.2 Screen 0 — mode select

```
┌─ BrainlessLab ────────────────────────────────────────────────────┐
│  What do you want to do?                                          │
│                                                                    │
│  > Run a task          simulate → static figure                   │
│    Watch it move       simulate → animate → GIF                   │
│    Explore live        launches the GLMakie window (Play/Step)    │
│    Replay a past run   pick a run dir → visualize/animate again   │
│    Train a genome      evolve() — long-running, hands off         │
│    Compare nodes       launches bench/ (non-interactive)          │
│    Build a profile     launches profile/ (non-interactive)        │
│                                                                    │
│  ↑↓ move   ↵ select   q quit                                      │
└────────────────────────────────────────────────────────────────────┘
```

The last three items are deliberately terminal leaves — picking them prints the equivalent shell command
(and optionally shells out to it) rather than opening more menus, keeping the TUI from having to re-model
bench/evolve/profile's much larger config surfaces.

### 2.3 Screen 1 — node select (registry-driven)

Populated by `variants()` — never a hardcoded list. Group by family so the settled-vs-experimental
distinction (from `nodes.md`) is visible, since that's the single most important piece of orientation for a
newcomer:

```
┌─ Pick a node ──────────────────────────────────────────────────────┐
│  Falandays family (paper-faithful baseline)                        │
│  > falandays_base        ★ stable baseline           [:falandays]  │
│    falandays_noisy         + sensory input noise                   │
│    falandays_ablated       target-homeostasis frozen               │
│    falandays_hemispheric   split hemispheres, callosum coupling    │
│    falandays_oosawa        + membrane drive (Oosawa)                │
│    falandays_spatial       distance-kernel connectivity             │
│    falandays_delayed       per-edge conduction delays               │
│                                                                      │
│  Compartmental / CTRNN family (experimental — needs training)      │
│    compartmental_dense                                              │
│    compartmental_structured  (recommended compartmental build)      │
│                                                                      │
│  ⚠ compartmental nodes have emergent, untrained weights — pick      │
│    "Train a genome" first, or expect near-random behaviour.         │
└──────────────────────────────────────────────────────────────────────┘
```

The "★ stable baseline" / "⚠ needs training" annotations are metadata that **does not exist on the
registry today** (see §5 — this is the main thing the package would need to add). Absent that metadata a
v0 TUI can still work off a hardcoded family-prefix heuristic (`startswith("compartmental")`, matching
`demo/run.jl`'s existing `_family()` helper) plus a static string table lifted from `nodes.md`, but that's a
maintenance smell the metadata fixes properly.

### 2.4 Screen 2 — task/setup select

Populated by `tasks()`, filtered/labelled to show the two setups and, importantly, cross-checked against
the node just picked (hemispheric needs `n_receptors>=2 and n_effectors>=2` — true for every current task,
but the TUI should call the same validation `_validate_agent_ports` does and surface the
`DimensionMismatch` as a friendly message rather than a stack trace, if a future node has a stricter
requirement):

```
┌─ Pick a task ───────────────────────────────────────────────────────┐
│  Agent–environment (single agent, PassthroughBody)                  │
│  > wall              R=2   E=2   ticks≈ default   score∈[0,77.3]    │
│    tracking          R=62  E=2                                      │
│    pong              R=46  E=2   score = mean paddle-ball align     │
│    pong_hitrate      R=46  E=2   score = hit rate                   │
│    cartpole          R=8   E=2                                      │
│    cartpole_hard/swingup/long   (variants)                          │
│                                                                       │
│  Collective (multi-agent, VENBody, n_agents)                        │
│    torus             R=64  E=3   no TaskSpec — read via metrics     │
│                       (polarization / milling / liveness)           │
└─────────────────────────────────────────────────────────────────────┘
```

R/E/ticks/score-range come straight off `TaskSpec` (`n_receptors`, `n_effectors`, `default_ticks`,
`default_window`, `score_floor`/`score_ceiling`, `score_key`) — again all introspectable, no hardcoding.
`:torus`'s R=64/E=3 note (62 bearing sensors zero-padded to 64, per `receptors-effectors.md`) is worth a
one-line callout since it's the one place today where "R" doesn't equal "number of physical sensors."

### 2.5 Screen 3 — params

Three tiers, cheapest first:

```
┌─ Parameters — falandays_base on wall ─────────────────────────────┐
│  N (n_nodes)      [ 100 ]   default for falandays family           │
│  seed             [  0  ]                                          │
│  ticks            [ default: 2000 ]   (TaskSpec.default_ticks)     │
│                                                                      │
│  ▸ advanced (node kwargs) ...............................  [ ] show│
│                                                                      │
│  [ Run ]   [ Back ]                                                 │
└──────────────────────────────────────────────────────────────────────┘
```

Expanding "advanced" reveals node-specific kwargs — for `falandays_hemispheric`: `callosum_density`,
`contralateral`, `p0`, `lambda`, `link_p`, `extent`; for `falandays_delayed`: `conduction_velocity`; for
`falandays_spatial`: `p0`, `lambda`; for `falandays_oosawa`: `membrane_noise`, `noise_gain`; for
`falandays_noisy`: `sensory_noise`; for compartmental: `link_p`, `rho`, `k_rec`/`k_in`, `raw_scale`,
`state_scale`, `dt`. For `:torus`, `n_agents` appears as a first-tier field alongside N.

This is the other place metadata is missing today (§5): the TUI has no principled way to know *which*
kwargs a given node constructor accepts, their types, or sane ranges, short of pattern-matching the
constructor's keyword-argument list via `Base.kwarg_decl`/`methods` introspection (fragile — closures used
as constructors in the registry don't always expose readable kwarg lists) or hardcoding a param table per
node (works, but is exactly the kind of list the registries were built to avoid).

### 2.6 Screen 4 — confirm & dispatch

```
┌─ Ready ────────────────────────────────────────────────────────────┐
│  simulate(:wall; node=:falandays_base, n_nodes=100, seed=0)         │
│  → animate(sim; path="…/activity.gif")                              │
│                                                                       │
│  [ Run ]   [ Edit params ]   [ Copy as Julia call ]                  │
└────────────────────────────────────────────────────────────────────┘
```

"Copy as Julia call" matters pedagogically — the whole point of the two-line API (`sim = simulate(...);
visualize(sim)`) is that participants graduate off the TUI into the REPL. Showing the literal call the TUI
is about to make (and letting them copy it) is cheap and directly serves that goal.

### 2.7 Output handling

- **Static figure** (`visualize`): save PNG under `demo/output/` (or a TUI-specific `tui/output/`) and
  print the path; optionally shell out to `open`/`xdg-open`.
  - Note the current Makie extension methods (`visualize`, `animate`, ...) require a backend to already be
    `using`'d (`CairoMakie` for save, `GLMakie` for `explore`) — see `demo/run.jl`'s top-level `@eval using
    ...` dance and its `Base.invokelatest` calls to dodge world-age issues from a runtime `using`. A TUI
    that offers both "save a figure" and "explore live" in the same session inherits this exact problem and
    needs the same pattern (load CairoMakie eagerly at startup for -save paths; lazily attempt GLMakie only
    when "Explore live" is chosen, `invokelatest` everything downstream of that load).
- **GIF** (`animate`): save + print path; optionally open it.
- **Explore** (GLMakie window): print "opening interactive window — close it to return to the menu," call
  `explore(...)`, block until the figure closes (GLMakie's own loop owns the terminal's foreground while
  open), then return to the menu. This is a real UX seam: a slow GLMakie precompile/launch on first use
  should be flagged ("first launch may take Xs to precompile") so it doesn't read as a hang.
- **Replay**: list `demo/runs/*` and `bench/runs/*` (and any TUI-specific run root) by directory name/
  timestamp, call `replay(rundir)::SimResult`, then re-offer visualize/animate on the restored `SimResult`.
- **Text summary**: for a plain `simulate` with no viz requested, print `sim.metrics` as a small table
  (score/liveness/polarization/milling as applicable) — the terminal-only path for people without a Makie
  backend installed at all, or running headless/over SSH.

## 3. Scope options

### v0 — minimal REPL-menu launcher
A linear wizard: `REPL.TerminalMenus.request`/`RadioMenu` for each screen above, one screen at a time,
`println` for output, no persistent layout, no live preview. Essentially `demo/run.jl`'s flag-parsing
replaced by prompts, plus the node/task pickers being registry-driven instead of `--list`. Ships as a
single script (`tui/run.jl`) runnable the same way `demo/run.jl` is. No new deps beyond stdlib `REPL`.

### v1 — richer panelled TUI
A persistent full-screen layout: left pane = registry browser (nodes/tasks with live-updating
description/R-E/param panel as selection moves, no need to commit-then-see), right pane = a running log /
last result summary, bottom = param form. Could add a lightweight "preview" — e.g. render the first N ticks'
rate trace as a terminal sparkline while params are being tuned, before committing to a full run. This tier
is where a library like Term.jl (panels/layout) or Tachikoma.jl (real widgets: forms, tables, live redraw)
earns its keep; `REPL.TerminalMenus` cannot do persistent multi-pane layout.

### Recommended phased path
**v0 first, ship it, use it for a summer-institute session, then decide on v1 from actual friction reports**
rather than guessing. The registries are already the hard part done; v0 is mostly UI plumbing over
`simulate`/`visualize`/`animate`/`explore`/`replay`, which are all stable today. v1's value is speculative
until people have used v0 and said "I wanted to see X before committing to a run."

## 4. Implementation survey (Julia ecosystem)

| option | capability | dependency weight | maintenance (as of mid-2026) | fit |
|---|---|---|---|---|
| **`REPL.TerminalMenus`** (stdlib) | Single-select/multi-select/radio menus, request loop. No panels, no persistent layout, no forms — you compose screens by clearing and reprinting. | **Zero** — ships with Julia itself, part of `REPL` stdlib. | Ships with Julia core; as stable as the language. | Best fit for the package's "no heavy deps" ethos. Sufficient for the whole v0 flow above (mode → node → task → params-as-prompted-numbers → confirm). |
| **Term.jl** (`FedeClaudi/Term.jl`) | Rich styled output: `Panel`, `TextBox`, `Tree`, markdown rendering, tables, progress bars, layout composition via nesting/stacking renderables. Not primarily an *interactive-input* framework — it's closer to "rich `println`" (à la Python's `rich`) than a full event-loop TUI; menus/selection still need something else layered on top (often paired with `REPL.TerminalMenus` for the interactive bits). | Moderate — one extra dependency, pure Julia, no C bindings. | Actively used/documented, reasonably mature (v1.0 stable API as of the syntax migration to `{...}` markup). | Good fit **if v1** wants nicer static panels (the registry browser's description pane, a boxed confirm screen, a styled params table) without committing to a full alternate-screen event loop. Could be layered *on top of* `TerminalMenus` rather than replacing it. |
| **TerminalUserInterfaces.jl** (`kdheepak`) | Elm-architecture (Model/update!/view) immediate-mode TUI with double-buffered diffed redraw — a real event loop, closer to Rust's `ratatui`/Go's `bubbletea`. | Moderate-heavy — pure Julia but a full framework commitment (own render loop takes over the terminal). | Smaller community; less active than Term.jl; API described in its own docs as evolving. | Plausible for v1's persistent multi-pane layout, but heavier framework buy-in than the task needs, and thinner community backing than Term.jl. |
| **Tachikoma.jl** (`kahliburke/Tachikoma.jl`) | Newer (2026) pure-Julia full TUI framework: Elm-inspired Model/update!/view, 60fps double-buffered event loop, 30+ widgets (text input, forms w/ Tab navigation + validation, data tables, tree views, sparklines/charts, modals, dropdowns, progress), constraint-based layout (Fixed/Fill/Percent/Min/Max/Ratio), Kitty/sixel graphics, recording/export to SVG/GIF. 100% Julia, no C/ncurses deps. | Moderate-heavy — same framework-commitment shape as TerminalUserInterfaces.jl, but far more batteries (real form widgets are exactly what the params screen wants). | **Very new** (discourse announcement in 2026) — capable and well-documented already, but unproven maintenance track record; adopting it is an early-adopter bet. | The most *capable* fit for a v1 "live preview + param forms + results pane" build — a real form widget with validation beats hand-rolled numeric-input parsing. Risk is entirely maturity/longevity, not capability. |
| **TextUserInterfaces.jl** (`ronisbr`) | Wraps ncurses directly; windows, widgets, decorations. | Heavy — C library binding (ncurses), platform-dependent build. | Maintained but niche. | Poor fit: the ncurses dependency is exactly the "heavy dep" the package's compute-core-stays-clean ethos is trying to avoid, for capability `REPL.TerminalMenus`+Term.jl already covers. |

**Recommendation: `REPL.TerminalMenus` for v0, unconditionally** — it's already in every Julia install, matches
the package's existing "compute core stays clean, viz/UI lives in extensions/subprojects" philosophy (same
posture as the Makie weakdep), and the v0 flow above doesn't need anything richer than select-menus and
`readline`-style prompts.

**For v1, if/when it's built: Term.jl layered over `TerminalMenus`**, not a full framework switch. Term.jl's
panels give the "legible sensorimotor contract + live description pane" polish without taking over the
terminal's control flow, so v0's menu-driven navigation model survives mostly intact — v1 becomes "v0's
screens, prettier and with a persistent side panel," not a rewrite. Flag Tachikoma.jl as the thing to
revisit if v1 wants real interactive forms/live preview/sparklines and Bird is comfortable with a young
dependency — it is a better *capability* match than Term.jl for that specific ambition, just less proven.

## 5. Architecture

### 5.1 Where it lives
A sibling subproject, `tui/`, following exactly the `demo/`/`bench/`/`profile/` pattern already established:
own `Project.toml` with `Pkg.develop(path="..")` against the parent package, own entry script (`tui/run.jl`),
zero footprint on the core package's `Project.toml`. This keeps `REPL.TerminalMenus` (stdlib, free) or a v1
`Term`/`Tachikoma` dependency entirely out of `BrainlessLab`'s own `[deps]`/`[weakdeps]` — consistent with
the Makie-via-package-extension precedent (`ext/BrainlessLabMakieExt.jl`, `[weakdeps] Makie`).

If the TUI needs to trigger a figure save it should either `using CairoMakie` itself (mirroring
`demo/run.jl`'s top-level backend load) or shell out to `demo/run.jl --save` as a subprocess for that one
action — the former keeps everything in-process (simpler state, but subject to the same
`Base.invokelatest`/world-age handling `demo/run.jl` already works around); the latter is more robust
against Makie-load ordering bugs but loses the "restore the resulting `SimResult` for a follow-up view"
capability that in-process gives for free. Recommend in-process, reusing `demo/run.jl`'s pattern directly
(worth literally importing/duplicating its `_family`, `_demo_config`, `save_run_dir` helpers rather than
reinventing).

### 5.2 Registry introspection
Everything menu-populating already exists and needs no new API:

```julia
variants()          # node symbols
tasks()              # task symbols
analyses()           # analysis symbols (branching_ratio today)
resolve_task(sym)    # -> TaskSpec, gives n_receptors/n_effectors/default_ticks/default_window/score_*
resolve_node(sym)    # -> constructor (opaque; see gap below)
```

`RunConfig`/`ModelSection`/`TaskSection`/`EvolveSection` (`run/Config.jl`) are the natural target shape for
"confirm & dispatch" — the TUI can build a `RunConfig`, call `resolve(cfg)` the same way `demo/run.jl` does
via `_demo_config`, and get `write_config`/`capture_manifest`/`run_dir` archiving for free if a run should be
saved with full provenance (git SHA, seeds, resolved params) rather than being a disposable preview.

### 5.3 The metadata gap (what the package would need to expose)
Two things menus want that the registries don't carry today:

1. **A human label + status tag per node/task** — "stable baseline" vs "experimental" vs "needs training,"
   a one-line description, which family it belongs to. Today this lives only in `nodes.md` prose and in
   `demo/run.jl`'s `_family()` heuristic (`startswith(String(node), "compartmental")`). A minimal fix: a
   `NODE_META::Dict{Symbol,NamedTuple}` (label, family, status, blurb) alongside the `NODES` registry,
   populated at the same `register_node!` call sites — e.g. `register_node!(:falandays_hemispheric,
   _falandays_hemispheric_native; status=:experimental, blurb="split hemispheres, callosum coupling")`
   (would need `register_node!`'s signature extended with optional kwargs, defaulting so existing call
   sites keep working).
2. **Per-node kwarg schema** — names, types, defaults, and (ideally) ranges for the "advanced" params
   screen. Nothing today declares this; kwargs are absorbed via `kwargs...` splats deep in
   `api/Highlevel.jl`'s `_falandays_*_native`/`_compartmental_native` functions. Two honest paths: (a)
   hardcode a small param table per node inside `tui/` (fast, but a second source of truth that will drift
   from the constructors — same risk `demo/run.jl`'s `_family()` already has), or (b) add a lightweight
   `paramschema(node_sym) -> Vector{(name, type, default, range)}` registered alongside `register_node!`,
   analogous to how `pack_params`/`paramdim` already formalize the *evolvable* parameter surface for
   compartmental genomes (`contracts.md`) — this would be the "do it right" version but is real package
   work, not a TUI-side hack. **Recommend v0 ship with the hardcoded table** (it's ~9 nodes, a day's work,
   and matches `nodes.md`'s existing hand-maintained kwarg tables) and revisit (b) only if a v1 registry-
   metadata pass happens for other reasons (the same metadata would also improve `--list` output and
   generated docs).

### 5.4 Dispatch surface
The TUI's Julia surface is small and entirely composition, no new core logic:

```julia
sim = simulate(task; node, seed, ticks, n_agents, node_kwargs...)   # headless
visualize(sim; panels)                                              # static figure (needs CairoMakie)
animate(sim; path, framerate)                                       # GIF (needs CairoMakie)
explore(task; node, kwargs...)                                      # blocks; needs GLMakie
sim = replay(rundir)                                                 # restore a SimResult
cfg = RunConfig(...); run_from_config(cfg)                           # archived run w/ manifest
run_sweep(sweep_toml)                                                 # (out of v0 scope, noted for completeness)
evolve(; ...) / EvolveRunner(...)                                     # hand off, don't wrap
```

None of this requires touching `src/`. The only package-side change worth making *for* the TUI (not
required to ship v0) is the metadata gap in §5.3.

## 6. Open questions for Bird to rule on

1. **Scope of v0**: agent–environment + torus simulate/animate/explore/replay only, with evolve/bench/
   profile as "print-the-command-and-optionally-shell-out" leaves — agreed, or should v0 omit those three
   leaves entirely and stay purely simulate/visualize/animate/explore/replay?
2. **`demo/run.jl` fate**: leave it standing alongside `tui/` (duplication of `_family`/`_demo_config`/
   `save_run_dir` helpers, but simple and independently scriptable), or have the TUI's "quick run" action
   literally shell out to `demo/run.jl` with flags built from menu choices (no duplication, but couples the
   TUI to demo's CLI surface staying stable)?
3. **Metadata gap (§5.3)**: hardcode the label/status/param-schema tables inside `tui/` for v0 (fast, second
   source of truth), or is a small `register_node!`-adjacent metadata extension in core worth doing now
   so `--list`/docs/TUI all read one source? This is the one place a "TUI" ask touches core package design.
4. **Run provenance**: should every TUI run auto-archive via `RunConfig`/`run_from_config` (full manifest,
   git SHA, resolved TOML — heavier but reproducible, matches the "framework for others" ethos), or should
   TUI runs be disposable-by-default (fast iteration) with an explicit "save this run" action, mirroring
   `demo/run.jl`'s `--save` flag?
5. **In-process vs subprocess for viz**: in-process (§5.1 recommendation, reuses `Base.invokelatest`
   pattern, keeps `SimResult` alive for follow-up views) vs shelling out per-action (more robust to Makie
   load-order bugs, loses that continuity) — worth a short spike before committing, since the
   `invokelatest`/world-age handling is the fiddliest part of the whole design and `demo/run.jl` is the only
   existing reference for how much it actually costs in practice.
6. **v1 library bet**: if/when v1 happens, is Bird comfortable depending on Tachikoma.jl (capable, very new,
   maintenance unproven) for the params-as-forms/live-preview ambition, or should v1 stay conservative with
   Term.jl-over-`TerminalMenus` and hand-roll whatever forms/preview it needs?

## Recommended concrete v0

- New sibling subproject `tui/` (own `Project.toml`, `Pkg.develop(path="..")`), entry `tui/run.jl`,
  zero new deps beyond stdlib `REPL.TerminalMenus`.
- Flow: mode select → node select (grouped by family, `variants()`-driven, hardcoded label/status/blurb
  table for now) → task select (`tasks()`-driven, `TaskSpec` fields shown live) → params (N/seed/ticks/
  n_agents as first-tier prompts; a hardcoded per-node kwarg table for the "advanced" tier) → confirm
  (prints the literal `simulate(...)` call) → dispatch to `simulate`/`visualize`/`animate`/`explore`/
  `replay`, reusing `demo/run.jl`'s CairoMakie/GLMakie top-level-load + `invokelatest` pattern verbatim.
  `evolve`/bench/profile are terminal leaves that print the equivalent shell command and offer to run it as
  a subprocess.
- No new core package code required to ship this; the one core-adjacent addition worth scoping separately is
  the `register_node!` metadata extension in §5.3, deferred unless/until v1 or a `--list`/docs pass wants it
  too.
