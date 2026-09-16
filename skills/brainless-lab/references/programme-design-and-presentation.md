# From a question to a readable programme

Use this workflow when a researcher wants to investigate a question, extend a study or
share its evidence. Keep the research tree, executed records and editorial choices distinct.
Use the existing ExperimentSpec and operations; do not create another experiment runner.

## Frame the question with the researcher

Start with the phenomenon they want to explain. Restate the smallest discriminating
comparison in plain language, including what stays fixed. Identify the primary outcome,
independent unit and an observation that would count against the proposed explanation.
Hypotheses are optional: a descriptive question does not need a fabricated prediction.

Offer a concrete draft using known context. Ask only for unresolved scientific choices
that change the interpretation: for example, what "frozen" means or what loss is acceptable.
Resolve implementation details from the active constructor and task contract yourself.
Distinguish the user's adopted hypothesis from an agent's suggestion. Do not silently
change the research question or primary endpoint when a result is inconvenient.

Record the adopted question, description, optional hypotheses/objectives, conditions and
limitations in ExperimentSpec. Put additional questions in child nodes; leave operations
empty until their comparison is defined. Separate primary comparisons from supporting
controls. A factorial set of switches does not establish independent mechanisms.

For initialisation studies, trace scale to realised weights. Target adaptation changes
thresholds even when weights are fixed. Distinguish weights frozen from all adaptation
disabled. Decide whether the question concerns raw starts or prepared states; do not
discard warm-up automatically. Capacity probes also require opportunity and readout checks.

## Execute and preserve the reasoning

Use check-experiment first, then execute the authorised bounded branch. Inspect failures,
resolved settings, seed pairing, outcome definitions and independent counts before expanding.
Software conformance is separate from results that answer the scientific question.

Attach runs with attach_experiment_run!. Preserve unsuccessful and inconclusive evidence.
Append discussion with add_experiment_note!, including author and relevant run IDs.
State what was observed, what it suggests, competing explanations and the next decision.
A later interpretation gets a new dated note. New hypotheses derived from inspected data
are exploratory; they do not become prior predictions by being added to the tree.
Keep executed records immutable and version substantive protocol changes.

## Select figures for meaning

Choose the figure that most directly answers the item's question. Usually this is a
comparison across the full declared range with the relevant control, paired differences
and uncertainty. Keep raw units visible; task-normalised scores are not interchangeable.
Inspect sample counts, missing values, failures, scoring windows and aggregation before
choosing the image. A visually striking trajectory is not evidence of a typical effect.

Prefer plots generated from recorded tables. Identify the source run and operation,
caption the contrast and explain uncertainty. A representative trace needs a stated
selection rule and an aggregate view. Do not select seeds, intervals or conditions for
their favourable appearance. Retain contradictory outcomes and supporting controls.
Keep activity/error plots as diagnostics unless the question explicitly concerns them.
Use scientific plotting tools for new data figures; generated decorative imagery must
never stand in for measurements. The current built-in programme charts show means;
intervals and independent counts remain in the linked operation reports and tables.

## Curate one programme page

Use one page with a linked tree and a shared format per item: title, question, description,
evidence state, optional hypotheses/objectives, selected figures and dated discussion.
Question-only follow-ups remain brief. Avoid repeating the question as the description.
Keep methods, full records and other diagnostics expandable. Do not make one article per
branch or automatically insert every operation's plots into the main reading flow.

Place presentation.toml beside experiment.toml. It changes display only; it does not
filter trials, rerun analysis, remove attachments or promote evidence. For example:

```toml
format_version = 1

[[items]]
branch = "reproduction/wall"
show = ["description", "hypotheses", "discussion"]
figures = ["run_0002/wall_comparison/Raw task score"]
```

Use the exact figure references listed under each operation's expandable diagnostics.
References identify an attached run, operation and generated figure title. The example
run ID is a placeholder for the actual attachment. Missing or wrong-branch references
fail export. Omitted items use all optional prose sections and no foreground figures.
An empty show list keeps the question, status, limitations and records visible.
Individual figures follow the authored selection order; tree order follows ExperimentSpec.
Notes currently display escaped Markdown source, so use plain paragraphs for clean prose.

Render to a fresh directory with report-experiment or render_experiment. Inspect the
whole page at desktop and narrow widths, figure labels, navigation, disclosure controls
and offline record links. Check that historical results stay labelled historical and
unrun questions do not look answered. Keep the full export directory when sharing.
Rendering is local; publishing and human acceptance are separate actions.
