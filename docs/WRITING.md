# Writing for BrainlessLab

Use this guide for README files, the public site, skills, examples, and user-facing error
text. The aim is plain technical writing, not formal ASD-STE100 compliance.

## Writing profile

Use a soft STE profile:

1. Give one main claim or instruction in each sentence.
2. Keep the actor, action, and object close together.
3. Use one preferred term for each technical concept.
4. State a condition before its consequence.
5. Introduce information in the order a reader needs it.
6. Use lists for sequences, alternatives, and sets of three or more items.
7. Remove promotional language, repeated conclusions, and decorative emphasis.

Aim for 12–25 words per sentence. A longer sentence is acceptable when splitting it would
hide a necessary qualification. Use active voice by default, but keep passive voice when
the method or result matters more than the actor.

Use British English in repository prose. Keep exact API names and quoted source terms
unchanged.

## Stable terms

Use these terms consistently:

| Term | Meaning |
| --- | --- |
| node | the local neural unit model |
| reservoir | a runtime population of nodes |
| `NodeSpec` | registered node metadata, builder, parameters, and capabilities |
| `TaskSpec` | registered task setup, ports, outcome, anchors, and defaults |
| body | the sensorimotor organisation coupled to a task |
| `InteractionCycle` | neural frames executed within one world step |
| `CompositionSpec` | the complete runtime composition |
| `EvaluationSpec` | the outer trial, seed, reset, and aggregation protocol |
| `EvaluationTarget` | one named composition with one evaluation protocol |
| operation plan | a profile, sweep, ablation, evolution, or benchmark plan |
| `ExperimentSpec` | a versioned scientific protocol over named conditions and operations |
| record | the portable output of one operation |

Use `simulate` for one in-memory run. Use an operation plan for repeated work. Do not call
`ExperimentSpec` another runner.

Use “validated on declared reference trajectories” for the tested Falandays conformance
boundary. Do not extend this wording to behavioural or biological equivalence.

Use “normalised score” only for the task-declared anchor transformation. Do not call it a
common competence scale. Use “evidence state” for planned, exploratory, tuned, frozen,
confirmed, promoted, or retired experiment status.

## Control claims

Separate four levels:

- what the code implements;
- what a test verifies;
- what an experiment observes;
- what the evidence can support.

Software readiness does not validate a biological interpretation. A complete record does
not make a result confirmed. A selected sweep cell is a development result. A task score
does not establish cognition, general competence, or external validity.

Avoid vague architecture metaphors when a precise term exists. Use “interface”, “method”,
“component”, “boundary”, “stage”, or the exact type name. Use “contract” only for a
declared interface, validation rule, or scoring definition.

## Review checklist

Before merging prose, check:

- every command, path, type, and field exists;
- public guidance uses the typed registries and current plan schema;
- no archived study route or bespoke experiment runner appears as current guidance;
- uncertainty and evidence status remain visible;
- links use stable routes;
- headings and paragraphs follow the reader's task;
- bold text marks only a genuine warning or definition;
- `git diff --check`, package tests, and the site build pass when applicable.
