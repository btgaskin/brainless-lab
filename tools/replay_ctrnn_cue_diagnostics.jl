using BrainlessLab, TOML

"""Recover recall decisions from saved development candidates and verify their original scores.

This is a linked diagnostic replay of existing blocks, never additional evidence.
It is useful for pilot records written before compact task-diagnostic columns were added.
"""
function replay_cue_diagnostics(; root="records/shared-ctrnn-pilot",
    output="benchmarks/ctrnn-readiness/development/candidate-cue-diagnostics.csv")
    rows = NamedTuple[]
    for directory in sort(readdir(root; join=true))
        isfile(joinpath(directory, "DONE")) || continue
        plan = read_plan(joinpath(directory, "request.toml"))
        plan isa EvolutionPlan || continue
        target = only(target for target in plan.training_targets if target.composition.task === :delayed_cue)
        resolved = resolve(plan, DEFAULT_REGISTRY)
        scores = BrainlessLab._read_record_csv(joinpath(directory, "data", "candidate_scores.csv"))
        source_trials = BrainlessLab._read_record_csv(joinpath(directory, "data", "candidate_trials.csv"))
        for candidate in BrainlessLab._read_record_csv(joinpath(directory, "data", "candidates.csv"))
            candidate.valid == "true" || continue
            coordinates = BrainlessLab._record_coordinates(candidate.coordinates,
                resolved.design.dimension, "diagnostic replay")
            model = BrainlessLab.Evolution.decode(resolved.design, coordinates)
            evaluation = BrainlessLab._evaluate_evolution_target(target, model, plan.run.measure, DEFAULT_REGISTRY)
            source = only(row for row in scores if row.candidate == candidate.candidate &&
                row.iteration == candidate.iteration && row.target == String(target.id))
            evaluation.aggregate == parse(Float64, source.score) || error("recall aggregate replay differs")
            for (trial, value) in zip(evaluation.trial_rows, evaluation.values)
                original = only(row for row in source_trials if row.candidate == candidate.candidate &&
                    row.iteration == candidate.iteration && row.condition == String(target.id) &&
                    parse(Int, row.block) == trial.block && parse(Int, row.trial) == trial.trial)
                value == parse(Float64, original.measure_value) || error("recall trial replay differs")
                push!(rows, merge((node=target.composition.node, search_seed=plan.run.search_seed,
                    source_record=basename(directory), iteration=parse(Int, candidate.iteration),
                    candidate=parse(Int, candidate.candidate), evidence_role=:linked_diagnostic_replay), trial))
            end
        end
    end
    BrainlessLab._write_csv(output, rows)
    println("verified recall diagnostic replays: ", length(rows))
    return rows
end

abspath(PROGRAM_FILE) == (@__FILE__) && replay_cue_diagnostics()
