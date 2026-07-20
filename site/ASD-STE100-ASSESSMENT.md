# ASD-STE100 documentation assessment

Date: 2026-07-19

Baseline: `571fd60`

Scope: all tracked Markdown and MDX documentation, including the two bundled agent skills

## Decision

BrainlessLab should adopt an **STE-informed documentation profile**. It should not claim
full ASD-STE100 compliance yet.

Use three writing modes:

1. **Controlled procedure** for setup, commands, tutorials, extension steps, and agent
   instructions.
2. **Controlled description** for concepts, contracts, API reference, limits, and design
   guidance.
3. **Scholarly description** for experiment reports and paper notes.

The first mode can target strict ASD-STE100 rules. The second mode can use almost all STE
structure rules, with an approved BrainlessLab terminology list. The third mode should use
the clarity rules, but it must preserve scientific qualification, equations, source terms,
paper titles, and quotations.

This approach gives low-code and no-code readers most of the benefit. It also prevents a
mechanical rewrite from changing scientific meaning.

## Basis for the assessment

The current standard is [ASD-STE100 Issue 9, January
2025](https://www.asd-ste100.org/assets/files/ASD-STE100_ISSUE9.pdf). Issue 9 fully replaces
the earlier issues.

The rules that are most useful for BrainlessLab are:

- Use approved words with one approved meaning and part of speech.
- Treat project terms as controlled technical nouns or technical verbs.
- Use the same technical noun for the same item.
- Use American English spelling, unless another directive controls the spelling.
- Use active voice. Use passive voice in descriptive text only when the agent is unknown.
- Give each sentence one topic.
- Do not use contractions.
- Use vertical lists for complex text.
- Use a maximum of 20 words in a procedural sentence.
- Put only one instruction in each procedural sentence.
- Put a necessary condition before its instruction.
- Use a maximum of 25 words in a descriptive sentence.
- Give each paragraph one topic and no more than six sentences.
- Prefer English phrases to Latin abbreviations such as “e.g.”, “i.e.”, and “etc.”

The [official FAQ](https://www.asd-ste100.org/STE_faq.html) states that STE can apply to
technical documentation in any industry. It also states that a checker is optional and
cannot replace the standard. Therefore, an automated check can help reviewers, but it
cannot certify this documentation.

## Corpus

This review covers 77 files.

| Surface | Files | Approximate prose words | Candidate sentences over 25 words |
| --- | ---: | ---: | ---: |
| Repository guides | 10 | 5,125 | 48 |
| Bundled agent skills | 16 | 14,579 | 206 |
| Core site pages | 22 | 15,060 | 133 |
| Experiment reports | 5 | 6,915 | 117 |
| Research notes | 24 | 15,454 | 233 |
| **Total** | **77** | **57,133** | **737** |

A lightweight scan also found:

- 281 candidate passive constructions;
- 36 Latin abbreviations;
- 70 selected British English spellings.

These values are triage signals. They are not compliance results. The scan removes
frontmatter, code fences, inline code, links, JSX, and some mathematical text. Markdown
lists and unusual punctuation can still produce false positives.

## What already works

The documentation has a good information architecture. The site separates onboarding,
concepts, contracts, workflows, extension guidance, experiments, and research notes.

The low-code entry path is clear. The Getting started page gives browser, agent-assisted,
and manual options. It also tells the reader what one run can and cannot establish.

The documentation already uses many good STE practices:

- Most procedures use direct commands.
- Tables and vertical lists contain complex information.
- Public API names appear as exact quoted identifiers.
- Limits and evidence states are explicit.
- Important terms have stable definitions on the Concepts and Contracts pages.
- The agent skills tell an agent to use repository evidence and report uncertainty.

These strengths make an STE profile practical. The work is mainly controlled editing and
terminology management. It does not require a new documentation architecture.

## Main gaps

### 1. Long sentences carry too many claims

The highest concentration is in experiment reports, research notes, and agent skills. A
long sentence often combines:

- a mechanism;
- a result;
- a qualification;
- an interpretation;
- a comparison.

Splitting these sentences will usually improve clarity. The editor must keep causal and
statistical qualifications attached to the correct claim.

### 2. Procedures and descriptions sometimes share one sentence

Some workflow pages explain a reason and give an instruction in the same sentence. Separate
the explanation from the command. Keep each work step as one imperative sentence.

### 3. The project has no controlled terminology file

The Concepts and Contracts pages define the ontology, but no machine-readable glossary
controls it. This creates risks such as:

- using “network” as a synonym for “reservoir”;
- using “body,” “morphology,” and `Embodiment` without a clear distinction;
- using “world,” “environment,” and “task” as if they own the same state;
- using “score,” “metric,” “measure,” and “analysis” without their contract boundary;
- using “need,” “drive,” “regulated variable,” and “feedback” without the modeled level.

The glossary must define preferred terms, permitted short forms, and prohibited synonyms.

### 4. Spelling is mixed

Current prose contains forms such as “behaviour,” “colour,” and “self-organising.” Strict
STE uses American English. A conversion should be repository-wide and atomic. It must not
change:

- Julia identifiers;
- file names or URLs;
- quoted paper titles;
- quotations;
- historical artifact names.

Do not make a partial spelling conversion. A partial conversion will increase
inconsistency.

### 5. The skills are accurate but dense

The BrainlessLab and Julia skills contain many compound sentences. These files are
instructions for agents, so they are high-value conversion targets. Shorter instructions
will also reduce ambiguity for automated readers.

The conversion must preserve normative strength. For example, do not change “must” to
“should” only to simplify a sentence.

### 6. Research notes need a separate rule profile

The paper notes include mathematical notation, specialized terminology, source-specific
language, and qualified claims. Strict dictionary enforcement would add noise and can
flatten distinctions.

Apply these rules to research notes:

- Use short sentences where the meaning remains stable.
- Give each paragraph one claim or topic.
- Use active voice when the agent is known.
- Define a specialized term at first use.
- Use one term for one concept.
- Keep uncertainty and scope qualifiers.
- Keep exact paper titles, quotations, equations, and symbols unchanged.

## Proposed BrainlessLab terminology seed

This is a starting set. It needs a separate review before it becomes normative.

| Preferred technical term | Controlled meaning |
| --- | --- |
| node | One neuron-like unit that implements `NodeModel`. |
| reservoir | A population of nodes, its wiring, and its dynamic state. |
| agent | One reservoir paired with one `AbstractBody`. |
| `AbstractBody` | The public dispatch boundary between a reservoir and a world. |
| `Embodiment` | The generic concrete composition of body components. |
| component | One configured part of an `Embodiment` with a stable component ID. |
| sensor | A component that samples physical state from a world. |
| encoder | A component that converts sensor samples into receptor values. |
| receptor | One input channel of a reservoir. |
| effector | One output channel of a reservoir. |
| actuator | A component that converts effector values into a typed command. |
| dynamics | A component that applies a command to motion state. |
| physiology | A component that owns regulated variables, effects, feedback, and viability. |
| regulated variable | A modeled internal quantity with a target or viable range. |
| need | A reader-facing description of deviation in a regulated variable. Do not use it as a new runtime type. |
| environment | The owner of external state and relations for an ensemble. |
| `ObjectWorld` | The generic fixed-population physical environment. |
| `SituatedEnvironment` | The adapter for the established torus, forage, and `:signalling` tasks. |
| task | The operational protocol, metric contract, and score interpretation for a research question. |
| ensemble | One or more agents that advance synchronously in one environment. |
| `EntityID` | A stable agent identity that does not depend on group or slot position. |
| `EntityFrame` | One recorded sample that keeps entity IDs attached to values. |
| recorder channel | One named time series in a `SimResult`. |
| score | A task-specific operational summary. Never use it as a universal unit. |
| metric | A named result from a task or run. |
| analysis | A function that derives a result from recorded channels. |
| null model | A data-generating or surrogate process that removes a specified relation. |
| cross-shift surrogate | A surrogate that changes relative timing across entity-aligned channels. |
| calibration | A mechanism or task check against a declared oracle, floor, ceiling, or expected response. |
| sweep | A bounded evaluation of declared parameter cells. |
| confirmation | Evaluation with a frozen protocol and independent, previously sealed blocks. |
| Falandays base | The fixture-validated authors-faithful baseline node update. |
| Falandays variant | A BrainlessLab experimental modification. |

Additional terminology should cover statistical units, evidence states, criticality
measures, homeostasis, object effects, development, and evolution.

## File classification

### Mode 1: controlled procedure

These files should target the strict procedural rules. Descriptive introductions within
the files can use Mode 2.

- `AGENTS.md`
- `CONTRIBUTING.md`
- `bench/README.md`
- `docs/README.md`
- `examples/embodiments/README.md`
- `examples/templates/new_project/README.md`
- `experiments/README.md`
- `profile/README.md`
- `site/README.md`
- `site/src/content/docs/agentic-workflow.mdx`
- `site/src/content/docs/extending.mdx`
- `site/src/content/docs/getting-started.mdx`
- `site/src/content/docs/research-workflow.mdx`
- `site/src/content/docs/task-reference.mdx`
- `site/src/content/docs/tooling.mdx`
- all files under `skills/brainless-lab/`
- all files under `skills/julia/`

### Mode 2: controlled description

These files should target the descriptive rules and the BrainlessLab terminology list.

- `README.md`
- `site/src/content/docs/analysis.mdx`
- `site/src/content/docs/collective.mdx`
- `site/src/content/docs/concepts.mdx`
- `site/src/content/docs/contracts.mdx`
- `site/src/content/docs/environments-tasks.mdx`
- `site/src/content/docs/evolution.mdx`
- `site/src/content/docs/index.mdx`
- `site/src/content/docs/introduction.mdx`
- `site/src/content/docs/nodes/falandays.mdx`
- `site/src/content/docs/nodes/neurons.mdx`
- `site/src/content/docs/nodes/overview.mdx`
- `site/src/content/docs/outputs/overview.mdx`
- `site/src/content/docs/platform-limits.mdx`
- `site/src/content/docs/receptors-effectors.mdx`
- `site/src/content/docs/reference.mdx`
- `site/src/content/docs/scoring.mdx`

### Mode 3: scholarly description

These files should use the adapted research profile.

- `site/src/content/docs/experiments/criticality-control.mdx`
- `site/src/content/docs/experiments/freeze-onset.mdx`
- `site/src/content/docs/experiments/overview.mdx`
- `site/src/content/docs/experiments/social-foraging.mdx`
- `site/src/content/docs/experiments/tracking-param-sweep.mdx`
- `site/src/content/docs/notes/activation-fronts-active-systems.mdx`
- `site/src/content/docs/notes/cognition-all-the-way-down.mdx`
- `site/src/content/docs/notes/collective-predator-evasion.mdx`
- `site/src/content/docs/notes/criticality-and-information.mdx`
- `site/src/content/docs/notes/criticality-collective-intelligence.mdx`
- `site/src/content/docs/notes/criticality-living-systems-review.mdx`
- `site/src/content/docs/notes/criticality-swarm-robots.mdx`
- `site/src/content/docs/notes/dynamical-criticality-overview.mdx`
- `site/src/content/docs/notes/emergent-macro-criticality.mdx`
- `site/src/content/docs/notes/finite-size-scaling-swarms.mdx`
- `site/src/content/docs/notes/heterogeneous-criticality-fish-school.mdx`
- `site/src/content/docs/notes/information-based-fitness.mdx`
- `site/src/content/docs/notes/information-flow-near-criticality.mdx`
- `site/src/content/docs/notes/papers-overview.mdx`
- `site/src/content/docs/notes/phase-transitions-collective-behavior.mdx`
- `site/src/content/docs/notes/scale-free-chaos-swarms.mdx`
- `site/src/content/docs/notes/soc-aquatic-robot-swarm.mdx`
- `site/src/content/docs/notes/soc-concepts-controversies.mdx`
- `site/src/content/docs/notes/soc-induced-by-diversity.mdx`
- `site/src/content/docs/notes/spectral-radius-criticality.mdx`
- `site/src/content/docs/notes/subcritical-escape-waves.mdx`
- `site/src/content/docs/notes/thermodynamics-collective-motion.mdx`
- `site/src/content/docs/notes/turning-avalanches-fish.mdx`
- `site/src/content/docs/notes/why-self-organize-to-criticality.mdx`

## Example edits

These examples show the intended method. They are not a request to change the pages before
the style decision.

### Agentic workflow

Current:

> BrainlessLab is designed to be operated with a coding agent, including by people who do
> not write Julia.

Proposed:

> People can operate BrainlessLab with a coding agent. They do not need to write Julia.

Current:

> The agent can translate intent, inspect contracts, run tools, implement changes, and
> collect evidence; the researcher still owns the question, risk boundary, interpretation,
> and decision to promote a result.

Proposed:

> The agent can translate intent, inspect contracts, run tools, implement changes, and
> collect evidence. The researcher controls the question, risk boundary, interpretation,
> and publication decision.

### Concepts

Current:

> Receptor and effector ports are namespaced by the owning component ID, so recording,
> overrides, and development target identities rather than tuple positions.

Proposed:

> The owner component ID forms the namespace for each receptor and effector port. Recording,
> overrides, and development use these identities instead of tuple positions.

### Scientific limits

Current:

> Fixture parity for `:falandays_base` validates the Julia node update against the local
> authors-derived reference construction on tested fixtures.

Proposed:

> Fixture parity tests the `:falandays_base` Julia node update. The test uses the local
> authors-derived reference construction and the declared fixtures.

The next sentence must keep the existing scope limit. A sentence split must not broaden the
validation claim.

### Skill instruction

Current:

> Prefer a kwarg/preset bundle over a whole new `<: Reservoir` when the change is
> parametric.

Proposed:

> If the change is parametric, use a keyword or preset bundle. Do not add a new
> `<: Reservoir` type.

The proposed version is longer in total, but it has a clearer condition and command.

## Tooling proposal

Add an advisory MDX-aware checker after the style profile is approved. The checker should:

1. Read a page mode from frontmatter or a path rule.
2. Ignore code, math, API identifiers, URLs, paper titles, and quotations.
3. Report sentences over the applicable 20-word or 25-word limit.
4. Report contractions, Latin abbreviations, selected passive forms, and mixed spelling.
5. Compare project terms with a controlled terminology file.
6. Report ambiguous pronouns for human review.
7. Produce line-based messages and a machine-readable summary.

The first release must be advisory. It should establish a baseline and reject only newly
introduced regressions. After editors convert a surface, CI can enforce its declared mode.

Do not use an automated rewrite as the acceptance gate. For scientific pages, require a
semantic review of:

- causal direction;
- statistical direction and effect sign;
- population and task scope;
- uncertainty;
- null and control definitions;
- units and equations;
- source attribution.

## Migration sequence

### Stage 1: approve the profile

- Approve the three writing modes.
- Decide whether prose will change to American English.
- Approve the first terminology list.
- Add page-mode metadata or a path-based policy.

### Stage 2: convert the entry path and agent instructions

Convert:

- `README.md`;
- Getting started;
- Agentic workflow;
- Research workflow;
- Tooling;
- both bundled skills.

These files have the largest immediate effect on low-code users and agents.

### Stage 3: convert contracts and extension guidance

Convert Concepts, Contracts, Extending, Environments and Tasks, Embodiment, Reference, and
Task Reference. Review code terms against the public API during the same change.

### Stage 4: convert the remaining core site

Convert the node, analysis, scoring, collective, evolution, outputs, and limits pages.

### Stage 5: edit experiment reports

Edit one experiment report at a time. Compare every revised claim with its result tables,
figures, and source data. Do not regenerate data during a prose-only change.

### Stage 6: edit research notes

Use the scholarly profile. Preserve source terminology and direct quotations. Check each
summary against its cited paper when the paper is available.

### Stage 7: introduce gradual enforcement

- Keep the checker advisory during the first conversion.
- Record the baseline for unconverted files.
- Enforce strict checks only on converted files.
- Require terminology and semantic review for new public pages.

## Acceptance criteria

The documentation can claim that it **uses an ASD-STE100-informed style** when:

- each file has a declared mode;
- the project terminology list is public and reviewed;
- procedure pages meet the selected procedural rules;
- descriptive pages meet the selected descriptive rules;
- scholarly exceptions are documented;
- code, math, and quotations are parsed as exceptions;
- the site build and link checks pass;
- a human reviews scientific meaning after each conversion.

Do not claim that the documentation is **ASD-STE100 compliant** unless trained reviewers
check the controlled dictionary, writing rules, project terminology, and every in-scope
page. Do not describe an automated checker as certification.

## Recommendation

Proceed with the profile, but convert the corpus in stages. Start with onboarding,
procedures, and agent skills. These surfaces will give the largest usability gain and the
lowest scientific risk.

Use controlled description for the core architecture. Use scholarly description for
experiments and literature notes. This boundary keeps the documentation clear without
removing necessary scientific nuance.
