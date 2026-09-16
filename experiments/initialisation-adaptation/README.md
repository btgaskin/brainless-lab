# Initialisation and continued adaptation

This programme asks whether homeostatic adaptation establishes a useful operating range,
continues to support task performance, or both. It turns Marc Bacvanski's observation into
explicit, inspectable comparisons. His exact settings are unknown; these protocols test
the described hypothesis rather than reproduce his particular runs.

The tree starts with word responses and completion, then the lab's Wall, Tracking and Pong
reference configurations. Each recurrent scale is crossed with weight updates on/off and
target updates on/off. Worlds and initial wiring are paired across these conditions.
The first scoring interval begins at tick 1: no warm-up observations are discarded.
Wall uses 200 ticks, Tracking 2000 and Pong 6000, matching each task's declared scoring
window. These are different task coordinates, not a common competence scale.

The later branches ask about the current benchmark, capacity probes, freeze timing and a
left/right sensory swap in Tracking. They deliberately contain questions and descriptions
without operations. They can grow one protocol at a time.

## Inspect and run a branch

`build_programme.jl` authors the checked-in `programme/` tree without simulation.
The complete proposed word branch contains 60 profiles, each with four development blocks;
each scored task has one benchmark with 48 trials. These are declared development budgets,
not an instruction to execute the whole programme.

```bash
julia --project=. bin/brainlesslab.jl check-experiment experiments/initialisation-adaptation/programme
julia --project=. bin/brainlesslab.jl report-experiment experiments/initialisation-adaptation/programme --output records/adaptation-plan
```

Open `records/adaptation-plan/index.html` to browse the questions. Once the selected stage
is authorised, execute exactly one runnable branch:

```bash
julia --project=. bin/brainlesslab.jl run-experiment experiments/initialisation-adaptation/programme --branch reproduction/wall --root records/adaptation
```

A parent never recursively executes its children. The run copies its selected protocol
and writes standard operation records, resolved settings, seeds, trial tables and reports.
`DONE` means software completion; it does not change the branch's evidence state.

## Attach results and discussion

```julia
using BrainlessLab
using BrainlessLab: attach_experiment_run!, add_experiment_note!, render_experiment
programme = "experiments/initialisation-adaptation/programme"
# Replace this placeholder with the directory printed by run-experiment.
run_id = attach_experiment_run!(programme, "reproduction/wall", "records/adaptation/RUN-ID")
add_experiment_note!(programme, "reproduction/wall";
    author="Researcher", text="Observed patterns and limitations.", runs=(run_id,))
render_experiment(programme, "records/adaptation-review")
```

The ledger is separate from the protocol and immutable runs. Attachment validates full
plan settings for the executed node and checksums. Adding child questions leaves that
node's unchanged results current; children are separate execution units. A different node
protocol requires explicit `historical=true` and
remains labelled historical. Dirty development provenance stays visible. Notes are dated,
authored Markdown files; the initial HTML renderer displays their escaped source text.
Edit a conclusion by adding another note, not by rewriting a prior note.

The export includes relative links, copied records, scale/paired-difference charts and
word diagnostic charts. It works offline and includes a checksum inventory. Keep the full
directory when sharing. Public acceptance still follows the existing human-maintained
research contribution process. Local attachment does not accept or promote evidence.

The page keeps operation diagnostics inside expandable methods and records. Select
foreground figures and optional prose through `presentation.toml` beside the root
`experiment.toml`. Each figure's exact selection reference appears in its diagnostic
section. The public [operations guide](../../site/src/content/docs/handbook/operations.mdx)
documents the format. Presentation changes leave the executed protocol and run checksums
unchanged; the export preserves these editorial settings separately.

## Word-task source boundary

The source is the [Falandays, Nguyen and Spivey implementation](https://github.com/bfalandays/HomeostasisModel),
at commit `98d18c0736e3e24312e19fe6a7a47f4deb625e97`, especially
`Homeostasis-as-prediction_1run_v2.ipynb`. The lab mapping uses leak fraction
0.25 for the source's retention 0.75, positive minimum targets, threshold multiplier 2,
normal recurrent weights and sensory amplitude 5. An independent equation test compares
activation, spikes, weights and targets from explicit identical initial states.

The probabilistic grammar exposes five lexical channels. Early/late display subjects
alternate as in the single-run source. Reported grammar probabilities are not conditional
probabilities of those forced display trials. Completion conditions rebuild paired
training histories; they do not preserve the notebook's state carryover between probes.
Random streams are not Python-identical. Two-cue completion uses the common verb, whereas
the notebook samples it. Early/late node rasters and the last-three-sentences/completion
correlation matrix are retained in analysis tables. The final 100 training sentences define
supplementary lexical templates, which are not the notebook's correlation measure.
When summarised across independently initialised networks, a node's raster series is a
spike frequency across trials, not an individual network's raster or a matched neuron.
Undefined correlations remain missing in charts. Spike counts and pre-update
homeostatic errors are diagnostics; this task declares no scalar performance objective.
Equation conformance does not establish full notebook or paper-result replication.

## Conformance and earlier drafts

`build_programme(destination; smoke=true)` creates a separately named software check:
two scales, two blocks, 16-node word reservoirs with ten training sentences and one-cue
completion, plus Wall. Its budgets and ID differ from the proposed study. Use it to check
execution, attachments, discussion and export before spending the full development budget.

The complete bounded check is executable as:

```bash
julia --project=. examples/programme_lifecycle.jl records/programme-conformance
```

This produces 16 word trials and 16 Wall trials, attaches the two experiment runs, adds
conformance notes and prints the offline report path. Use a fresh directory for a rerun.

The earlier `v1/pilot` and `v1/capacity-proposal` directories are retained drafts. The
Tracking draft discards 2000 warm-up ticks and is not the active raw-start reproduction.
Its earlier continuous-only sweep cannot answer the on/off comparison. Do not combine
those records with this protocol or count profile reruns as independent evidence.

Freeze timing needs a coarse curve before any knee search, a declared acceptable loss,
and a common later scoring interval. Capacity extensions need task opportunity and
readout checks. Shared prepared-state handoffs and reusable saved-record analysis
operations remain future work; existing analysis reports can already be attached and read.
