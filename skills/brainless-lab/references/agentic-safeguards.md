# Agent safeguards

BrainlessLab may be operated by a researcher who does not know Julia. Translate the
research intent into repository commands and public types. Do not ask the researcher to
choose a technical detail that the registry, code, or tests can resolve.

## Safe work loop

1. Read root `AGENTS.md` and the repository BrainlessLab and Julia skills.
2. Inspect the branch, worktree, dirty files, code, tests, plans, and record status.
3. State the intended outcome, allowed scope, evidence stage, and verification.
4. Use an isolated worktree for broad or parallel changes.
5. Verify component conformance before optimising behaviour.
6. Prefer composition and dispatch. Preserve stable component and entity IDs.
7. Run focused tests, then the applicable package, example, and site checks.
8. Use an independent read-only review for broad architecture or scientific changes.
9. Report the exact checks, task outcome when defined, software readiness, experiment
   evidence state, and remaining limits as separate facts.

## Human decisions

Pause before:

- changing the research question or primary endpoint;
- opening sealed evaluation data;
- increasing an expensive search cap;
- changing reference fixtures;
- modifying user data;
- publishing or changing unrequested external state.

Never silently:

- overwrite dirty user work;
- change a fixture to make a regression pass;
- call tuned or exploratory data confirmation;
- treat agents or ticks as independent trials;
- infer no effect from a non-significant test;
- describe a browser demonstration or simulated body as biological or robotic fidelity;
- promise cross-version bitwise reproduction from a seed alone.

## No-code and low-code responses

Lead with:

- what the researcher can accomplish;
- the smallest safe command or plan;
- the expected record or in-memory result;
- how success is checked;
- what the result cannot establish;
- the next scientific decision.

Keep Julia details secondary unless they affect correctness or the researcher asks to learn
them.

Use `simulate` for one diagnostic run. Use a typed operation plan for repeated work. Use
`ExperimentSpec` for a versioned scientific protocol. Do not create another runner or
configuration schema for agent convenience.

Use `site/src/content/docs/` as the public guide and
`site/src/content/docs/experimental/` for capability readiness. `available` and
`integrated` are software states. They do not promote an experiment or validate a
biological claim.
