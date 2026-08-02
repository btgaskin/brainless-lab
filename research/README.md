# Research contributions

This directory contains small, reviewable research records. It is not a general output
directory. Generated development runs remain outside Git.

Every new contribution starts from a versioned `ExperimentSpec` under `experiments/`.
Protocol or software changes are reviewed first. A later record-only pull request then
adds one accepted contribution at:

```text
research/contributions/<experiment-id>/v<version>/<contribution-id>/
├── contribution.toml
├── submission/
├── replay/
└── comparison.json
```

The final `contribution.toml` names the experiment path and version, source SHA,
contributor, reviewer, review URL, acceptance time, and reproduction state. It also lists
every file in `submission/` and `replay/` with its SHA-256 checksum. Set the reproduction
state to `accepted` only after the maintainer has completed the replay and review.

The submission is the contributor's complete experiment run. The replay is the
maintainer's run of the same protocol, configuration, seeds, and source revision. The
replay checks reproducibility, but it is not a second independent result.

Only UTF-8 TOML, CSV, JSON, Markdown, HTML, and `DONE` files are accepted. Each file is
listed with a SHA-256 checksum in `contribution.toml`. Symbolic links, figures, raw
traces, binary files, and extra files are rejected. Keep the complete contribution below
1 MiB. The validator enforces a 5 MiB hard limit.

The contributor adds `submission/` in a draft, run-only pull request. The maintainer adds
`replay/` and completes `contribution.toml` after review. A partial draft is not an accepted
contribution and does not enter `catalogue.json`.

Create the deterministic comparison after both runs are present:

```bash
julia --project=. bin/brainlesslab.jl compare-contribution <directory> --write
```

After the maintainer decides to accept the contribution, validate the complete bundle
against the repository, `origin/main`, and the pull-request base:

```bash
julia --project=. bin/brainlesslab.jl check-contribution <directory> \
  --repository . --main-ref origin/main --base origin/main
```

Then regenerate the catalogue before merge:

```bash
julia --project=. bin/brainlesslab.jl index-research
```

`catalogue.json` records protocols, roles, settings, targets, and artifact paths. It does
not combine task scores or interpret results. Read the linked summaries and trial tables
within their declared experiment and task.

Scripts and coding agents can filter the JSON by experiment, version, operation, target,
node, task, and resolved setting. They should follow the recorded paths instead of scanning
generated run directories. Their comparisons are advisory. A human maintainer remains
responsible for acceptance and scientific interpretation.

Accepted contribution directories are append-only. Correct a scientific protocol by
creating a new experiment version. Correct an accepted record by adding a new
contribution with a clear review trail.

The catalogue can include an explicit `pre-pipeline` compatibility record for older material.
That record must have indexed metadata and must not be described as contributor-maintainer
reproduction.
