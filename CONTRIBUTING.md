# Contributing to BrainlessLab

You do not need to know Julia before contributing. You can begin by running an existing
simulation, improving a task description, checking an example, or working with a coding
agent. The repository contains guidance for both humans and agents.

Start with the online [Getting started](https://brainless-lab.pages.dev/core/getting-started/)
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
  [Design a study](https://brainless-lab.pages.dev/core/design-study/).

[Extend the lab](https://brainless-lab.pages.dev/core/extend/) maps each public interface to
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

## Tests

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

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
