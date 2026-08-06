# Contributing to BrainlessLab

You do not need to know Julia before contributing. You can begin by running an existing
simulation, improving a task description, checking an example, or working with a coding
agent. The repository contains guidance for both humans and agents.

Start with the online [first simulation](https://brainless-lab.pages.dev/tutorials/first-simulation/)
guide. If you are using an agent, point it at `AGENTS.md`; that file tells it which
repository skills and safeguards to follow.

## Choose the smallest useful contribution

- **Use or reproduce:** run a checked-in example and report the exact command, Julia version,
  git commit, seed, and observed output.
- **Improve documentation:** correct the canonical Starlight page under
  `site/src/content/docs/`, then update repeated wording in the README, examples, or skills.
- **Add a neural substrate:** begin with `examples/templates/new_project/my_node.jl`.
- **Add a task:** begin with the same template for vector tasks or
  `examples/embodiments/object_world_task.jl` for physical tasks.
- **Add a body component:** extend the narrow physical interface and add strict config
  materialization, an example, and conformance evidence.
- **Add a metric or analysis:** declare its input channels, unit of analysis, diagnostics,
  valid null, failure behaviour, and scientific limitations.
- **Add an experiment:** compose named conditions and typed operations in an
  `ExperimentSpec`, then follow the evidence ladder in
  [Experiments and evidence](https://brainless-lab.pages.dev/handbook/experiments-evidence/).

[Extend BrainlessLab](https://brainless-lab.pages.dev/handbook/extending/) maps each public interface to
its example and required tests.

## Local setup

Install Julia using the [official Julia installer](https://julialang.org/install/), then
clone the repository and instantiate its pinned environment:

```bash
git clone https://github.com/btgaskin/brainless-lab.git
cd brainless-lab
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

Run the headless quickstart:

```bash
julia --project=. examples/quickstart.jl
```

The first run compiles the package and can be slower than later runs.

## Change discipline

1. Create a branch or isolated worktree.
2. Reproduce the current behaviour before editing.
3. Add or update the narrow contract test.
4. Implement through public dispatch boundaries.
5. Run focused tests, then the full applicable gates.
6. Update the canonical site page and executable example.
7. Keep exploratory output out of promoted research records.

Do not modify fidelity fixtures, committed evidence, or a sealed protocol merely to make a
new implementation agree with an expectation. If a scientific expectation changes, explain
why and start a new evidence cycle.

## Contribute a public research run

Research contributions use two stages. Merge the protocol and any software changes first.
Then run the merged protocol from a clean Git commit that is reachable from `main`.

The second pull request contains records only. A contributor submission and its maintainer
replay have linked roles in one contribution. They are not independent evidence or additional
replicates.

The contributor:

1. Include only records that can be public.
2. Keep each record complete, including its request, resolved configuration, seeds, data,
   summary, report, checksums, and `DONE`.
3. Aim to keep the text-only contribution at or below 1 MiB. The hard limit is 5 MiB.
4. Open a draft, run-only pull request containing the submission bundle. The final
   contribution check cannot pass until a maintainer has added the replay and review data.

Files above 5 MiB are not accepted by this Git-native pipeline. Large datasets remain out
of scope for this contribution path.

A maintainer replays the already-merged experiment at the submitted source SHA. The maintainer
then adds the replay record, compares the linked roles, and reviews the scientific boundary.
If the maintainer decides to accept the contribution, they complete its review fields and run
the final gates:

```bash
git fetch origin main
julia --project=. bin/brainlesslab.jl compare-contribution DIR --write
julia --project=. bin/brainlesslab.jl check-contribution DIR \
  --repository . --main-ref origin/main --base origin/main
julia --project=. bin/brainlesslab.jl index-research \
  --root research --output research/catalogue.json
```

Only a human maintainer accepts a contribution. Workflow success, replay agreement, and catalogue
generation do not accept evidence automatically.

Accepted records are immutable. Correct an interpretation with an annotation or superseding
protocol. Do not rewrite a published record.

The catalogue can include an explicit `pre-pipeline` compatibility entry for older material.
Such an entry is not a retrospectively accepted contribution.

## Tests

Run the fast Core contract tier first:

```bash
BRAINLESSLAB_TEST_SUITE=core julia --project=. -e 'using Pkg; Pkg.test()'
```

Then select the gates that match the change from [test/README.md](test/README.md).
Runtime, operation, scientific-oracle, legacy-compatibility, and visual tests
run independently. Bare `Pkg.test()` runs every suite and takes about fifteen minutes,
so do not use it as the ordinary local loop.

Site:

```bash
cd site
bun install
bun run build
```

The relevant change should also have a focused test. New hot-loop code should be checked
after warm-up for inference and avoidable allocations. New stochastic behaviour needs reset,
replay, stream-ownership, and iteration-order tests.

## Pull-request handoff

State:

- the question or user outcome;
- the public contract changed;
- exact checks run and their results;
- any performance measurement and its setup;
- the evidence status of scientific outputs;
- current limitations and follow-up work.

Keep implementation conformance, behavioural observations, and scientific claims separate.
